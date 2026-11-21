import Foundation

// MARK: - DLNA 客户端（方案 §7）
// SSDP M-SEARCH 发现 MediaRenderer 设备 + SOAP AVTransport 推流。
// 不引第三方库：SSDP 走 BSD socket（响应单播回源端口，普通 UDP socket 即可收），
// SOAP 走 URLSession POST。

final class DLNAClient {

    struct DiscoveredDevice {
        let location: URL      // 设备描述 XML 地址
        let usn: String
    }

    // MARK: SSDP 发现

    /// M-SEARCH 局域网内 DLNA 渲染设备（默认 4 秒收集窗口）
    func discover(timeout: TimeInterval = 4) async -> [DiscoveredDevice] {
        let searchTarget = "ssdp:all"
        let message = """
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        MAN: "ssdp:discover"\r
        MX: 2\r
        ST: \(searchTarget)\r
        \r

        """
        var seen: [String: DiscoveredDevice] = [:]
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let socket = Self.openSocket()
                defer { close(socket) }
                guard socket >= 0 else { cont.resume(); return }

                Self.send(socket, message: message, to: "239.255.255.250", port: 1900)
                // 发两轮，覆盖设备未监听第一包的情况
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) {
                    Self.send(socket, message: message, to: "239.255.255.250", port: 1900)
                }

                let deadline = Date().addingTimeInterval(timeout)
                var buffer = [UInt8](repeating: 0, count: 4096)
                while Date() < deadline {
                    guard Self.waitForData(socket, seconds: 0.5) else { continue }
                    let n = recv(socket, &buffer, buffer.count, 0)
                    guard n > 0 else { continue }
                    let text = String(decoding: buffer[0..<n], as: UTF8.self)
                    if let device = Self.parseResponse(text) {
                        seen[device.usn] = device
                    }
                }
                cont.resume()
            }
        }
        return Array(seen.values)
    }

    // MARK: 设备描述 XML

    /// 拉取设备描述，返回 friendlyName 与 AVTransport controlURL（相对路径已按 location 解析）
    func describe(device: DiscoveredDevice) async -> (name: String, controlURL: URL)? {
        guard let (data, resp) = try? await URLSession.shared.data(from: device.location),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let xml = String(data: data, encoding: .utf8)
        else { return nil }
        let name = Self.tagValue("friendlyName", in: xml) ?? "未知设备"
        guard let rawControl = Self.avTransportControlURL(in: xml) else { return nil }
        let control = URL(string: rawControl, relativeTo: device.location)?.absoluteURL
            ?? URL(string: rawControl)
        guard let control else { return nil }
        return (name, control)
    }

    // MARK: SOAP 控制（AVTransport:1）

    /// SetAVTransportURI + Play：把直链推给电视端
    func cast(url: URL, title: String, controlURL: URL) async throws {
        let escaped = url.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        let meta = """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
        <item id="0"><dc:title>\(title.xmlEscaped)</dc:title><upnp:class>object.item.videoItem</upnp:class></item>
        </DIDL-Lite>
        """.xmlEscaped
        try await soap("SetAVTransportURI", controlURL: controlURL, body: """
        <InstanceID>0</InstanceID>
        <CurrentURI>\(escaped)</CurrentURI>
        <CurrentURIMetaData>\(meta)</CurrentURIMetaData>
        """)
        try await soap("Play", controlURL: controlURL, body: """
        <InstanceID>0</InstanceID><Speed>1</Speed>
        """)
    }

    func stop(controlURL: URL) async throws {
        try await soap("Stop", controlURL: controlURL, body: "<InstanceID>0</InstanceID>")
    }

    private func soap(_ action: String, controlURL: URL, body: String) async throws {
        var request = URLRequest(url: controlURL)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        let envelope = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body><u:\(action) xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">\(body)</u:\(action)></s:Body>
        </s:Envelope>
        """
        request.httpBody = envelope.data(using: .utf8)
        let (_, resp) = try await URLSession.shared.data(for: request)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw CastError.deviceRejected(code: code) }
    }

    enum CastError: Error { case deviceRejected(code: Int) }
}

// MARK: - SSDP / XML 工具

private extension DLNAClient {

    static func openSocket() -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return -1 }
        // 允许复用 + 设置收包超时兜底（waitForData 已用 select）
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    static func send(_ fd: Int32, message: String, to host: String, port: UInt16) {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return }
        let sent = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                message.withCString { cstr in
                    sendto(fd, cstr, strlen(cstr), 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        _ = sent
    }

    static func waitForData(_ fd: Int32, seconds: Double) -> Bool {
        var set = fd_set()
        FD_ZERO(&set)
        FD_SET(fd, &set)
        let tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds.truncatingRemainder(dividingBy: 1)) * 1_000_000))
        return select(fd + 1, &set, nil, nil, &tv) > 0
    }

    static func parseResponse(_ text: String) -> DiscoveredDevice? {
        guard text.uppercased().contains("HTTP/1.1 200") else { return nil }
        var location: String?
        var usn: String?
        for line in text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
            let upper = line.uppercased()
            if upper.hasPrefix("LOCATION:") {
                location = line.dropFirst("LOCATION:".count).trimmingCharacters(in: .whitespaces)
            } else if upper.hasPrefix("USN:") {
                usn = line.dropFirst("USN:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let loc = location, let url = URL(string: loc), let usn else { return nil }
        // 只收渲染端设备（ST/USN 含 MediaRenderer 或 AVTransport）
        let up = text.uppercased()
        guard up.contains("MEDIARENDERER") || up.contains("AVTRANSPORT") else { return nil }
        return DiscoveredDevice(location: url, usn: usn)
    }

    static func tagValue(_ tag: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(tag)>"), let close = xml.range(of: "</\(tag)>", range: open.upperBound..<xml.endIndex)
        else { return nil }
        return String(xml[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 找 AVTransport 服务的 controlURL（serviceType 匹配后取同级 controlURL）
    static func avTransportControlURL(in xml: String) -> String? {
        let services = xml.components(separatedBy: "<service>").dropFirst()
        for service in services {
            guard service.contains("AVTransport") else { continue }
            if let url = tagValue("controlURL", in: service), !url.isEmpty { return url }
        }
        return nil
    }
}

private extension String {
    /// SOAP/XML 文本转义
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

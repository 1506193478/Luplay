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

    /// 设备 SOAP 端点（AVTransport 播放控制 / RenderingControl 音量）
    struct Endpoints {
        let avTransport: URL
        let renderingControl: URL?
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

    /// 拉取设备描述，返回 friendlyName 与 AVTransport/RenderingControl controlURL（相对路径已按 location 解析）
    func describe(device: DiscoveredDevice) async -> (name: String, endpoints: Endpoints)? {
        guard let (data, resp) = try? await URLSession.shared.data(from: device.location),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let xml = String(data: data, encoding: .utf8)
        else { return nil }
        let name = Self.tagValue("friendlyName", in: xml) ?? "未知设备"
        guard let rawAV = Self.controlURL(for: "AVTransport", in: xml), !rawAV.isEmpty else { return nil }
        let av = URL(string: rawAV, relativeTo: device.location)?.absoluteURL ?? URL(string: rawAV)
        guard let av else { return nil }
        let rc: URL? = Self.controlURL(for: "RenderingControl", in: xml).flatMap {
            URL(string: $0, relativeTo: device.location)?.absoluteURL ?? URL(string: $0)
        }
        return (name, Endpoints(avTransport: av, renderingControl: rc))
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

    // MARK: 远程控制（AVTransport + RenderingControl，投屏遥控用）

    func pause(controlURL: URL) async throws {
        try await soap("Pause", controlURL: controlURL, body: "<InstanceID>0</InstanceID>")
    }

    func resume(controlURL: URL) async throws {
        try await soap("Play", controlURL: controlURL, body: "<InstanceID>0</InstanceID><Speed>1</Speed>")
    }

    /// 跳转（REL_TIME，HH:MM:SS）
    func seek(to seconds: Double, controlURL: URL) async throws {
        let t = Self.timeString(seconds)
        try await soap("Seek", controlURL: controlURL, body: """
        <InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>\(t)</Target>
        """)
    }

    /// 设置音量（0-100，RenderingControl）
    func setVolume(_ percent: Int, renderingControlURL: URL) async throws {
        try await soap("SetVolume", controlURL: renderingControlURL, service: "RenderingControl", body: """
        <InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>\(percent)</DesiredVolume>
        """)
    }

    /// 查询音量（0-100），失败返回 nil
    func volume(renderingControlURL: URL) async -> Int? {
        guard let data = try? await soapResponse("GetVolume", controlURL: renderingControlURL,
                                                 service: "RenderingControl",
                                                 body: "<InstanceID>0</InstanceID><Channel>Master</Channel>"),
              let xml = String(data: data, encoding: .utf8),
              let raw = Self.tagValue("CurrentVolume", in: xml)
        else { return nil }
        return Int(raw.trimmingCharacters(in: CharacterSet.decimalDigits.inverted)) ?? nil
    }

    /// 查询播放位置与时长（秒）；设备不支持时对应值为 0
    func positionInfo(controlURL: URL) async -> (position: Double, duration: Double, isPlaying: Bool)? {
        guard let posData = try? await soapResponse("GetPositionInfo", controlURL: controlURL,
                                                    body: "<InstanceID>0</InstanceID>"),
              let posXML = String(data: posData, encoding: .utf8)
        else { return nil }
        let position = Self.seconds(Self.tagValue("RelTime", in: posXML)) ?? 0
        let duration = Self.seconds(Self.tagValue("TrackDuration", in: posXML)) ?? 0
        var isPlaying = false
        if let stateData = try? await soapResponse("GetTransportInfo", controlURL: controlURL,
                                                   body: "<InstanceID>0</InstanceID>"),
           let stateXML = String(data: stateData, encoding: .utf8),
           let state = Self.tagValue("CurrentTransportState", in: stateXML) {
            isPlaying = state.uppercased().contains("PLAYING")
        }
        return (position, duration, isPlaying)
    }

    private func soap(_ action: String, controlURL: URL, service: String = "AVTransport", body: String) async throws {
        _ = try await soapResponse(action, controlURL: controlURL, service: service, body: body)
    }

    private func soapResponse(_ action: String, controlURL: URL, service: String = "AVTransport", body: String) async throws -> Data {
        var request = URLRequest(url: controlURL)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:\(service):1#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        let envelope = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body><u:\(action) xmlns:u="urn:schemas-upnp-org:service:\(service):1">\(body)</u:\(action)></s:Body>
        </s:Envelope>
        """
        request.httpBody = envelope.data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: request)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw CastError.deviceRejected(code: code) }
        return data
    }

    /// 秒 → "H:MM:SS"（UPnP REL_TIME 格式）
    private static func timeString(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// UPnP 时间字符串 → 秒（"1:23:45" / "NOT_IMPLEMENTED" → nil）
    private static func seconds(_ raw: String?) -> Double? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2])
        else { return nil }
        return h * 3600 + m * 60 + s
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
        // Swift 不暴露 FD_ZERO/FD_SET 宏，改用 poll（等价的可读性检测）
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let timeout = Int32(max(0, seconds * 1000))
        return poll(&pfd, 1, timeout) > 0
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

    /// 找指定服务的 controlURL（serviceType 匹配后取同级 controlURL）
    static func controlURL(for serviceType: String, in xml: String) -> String? {
        let services = xml.components(separatedBy: "<service>").dropFirst()
        for service in services {
            guard service.contains(serviceType) else { continue }
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

import Foundation
import Network
import Security

// MARK: - Chromecast 客户端（CastV2 协议手写实现，不引官方 SDK）
// 发现：SSDP M-SEARCH（DIAL: urn:dial-multiscreen-org:service:dial:1），Chromecast 支持 DIAL 响应；
// 会话：TLS 8009 端口 socket + CastChannel protobuf（长度前缀帧）+ JSON 命令。
// 流程：CONNECT(receiver-0) → LAUNCH 默认媒体接收器(CC1AD845) → RECEIVER_STATUS 取 transportId
//      → CONNECT(transportId) → LOAD 直链 → 心跳保活；断开：STOP + CLOSE。
// 默认媒体接收器 appId CC1AD845 为 Google 公开测试标识，无需注册。

final class CastV2Client {

    struct DiscoveredDevice {
        let ip: String
        let name: String
        let usn: String
    }

    // MARK: - 发现（SSDP/DIAL）

    func discover(timeout: TimeInterval = 4) async -> [DiscoveredDevice] {
        // 两轮 M-SEARCH：service 与 device 两种 DIAL ST，覆盖不同固件
        let targets = ["urn:dial-multiscreen-org:service:dial:1",
                       "urn:dial-multiscreen-org:device:dial:1"]
        var seen: [String: URL] = [:]   // usn → LOCATION
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let socket = Self.openSocket()
                defer { close(socket) }
                guard socket >= 0 else { cont.resume(); return }
                for target in targets { Self.sendSSDP(socket, searchTarget: target) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) {
                    for target in targets { Self.sendSSDP(socket, searchTarget: target) }
                }
                let deadline = Date().addingTimeInterval(timeout)
                var buffer = [UInt8](repeating: 0, count: 4096)
                while Date() < deadline {
                    guard Self.waitForData(socket, seconds: 0.5) else { continue }
                    let n = recv(socket, &buffer, buffer.count, 0)
                    guard n > 0 else { continue }
                    let text = String(decoding: buffer[0..<n], as: UTF8.self)
                    if let device = Self.parseSSDP(text) { seen[device.usn] = device.location }
                }
                cont.resume()
            }
        }
        // 拉取 DIAL 设备描述 XML 拿 friendlyName（并发请求）
        var result: [DiscoveredDevice] = []
        await withTaskGroup(of: DiscoveredDevice?.self) { group in
            for (usn, location) in seen {
                let host = location.host ?? ""
                guard !host.isEmpty else { continue }
                group.addTask {
                    let name = await Self.friendlyName(from: location)
                    return DiscoveredDevice(ip: host, name: name ?? "Chromecast (\(host))", usn: usn)
                }
            }
            for await device in group {
                if let device { result.append(device) }
            }
        }
        return result
    }

    private static func parseSSDP(_ text: String) -> (usn: String, location: URL)? {
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
        // 仅收 DIAL 设备（Chromecast 走 DIAL；普通 DLNA 设备由 DLNAClient 处理）
        guard text.uppercased().contains("DIAL-MULTISCREEN") else { return nil }
        return (usn, url)
    }

    private static func friendlyName(from location: URL) async -> String? {
        guard let (data, resp) = try? await URLSession.shared.data(from: location),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let xml = String(data: data, encoding: .utf8)
        else { return nil }
        guard let open = xml.range(of: "<friendlyName>"),
              let close = xml.range(of: "</friendlyName>", range: open.upperBound..<xml.endIndex)
        else { return nil }
        return String(xml[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: CastV2 会话

    struct MediaStatus {
        let playerState: String   // PLAYING / PAUSED / IDLE
        let currentTime: Double
        let duration: Double
        let mediaSessionId: Int
    }

    private var conn: NWConnection?
    private var transportID: String?
    private var requestID = 0
    private var heartbeatTask: Task<Void, Never>?
    private var rxBuffer = Data()
    private var lastStatus: MediaStatus?
    private let lock = NSLock()   // 保护 transportID / requestID / rxBuffer / lastStatus

    /// 最近一次 MEDIA_STATUS 快照（遥控面板轮询用）
    func statusSnapshot() -> MediaStatus? {
        lock.lock()
        defer { lock.unlock() }
        return lastStatus
    }

    enum CastError: Error, LocalizedError {
        case connectFailed
        case receiverNotReady
        case notConnected
        var errorDescription: String? {
            switch self {
            case .connectFailed: return "无法连接 Chromecast（TLS 8009）"
            case .receiverNotReady: return "接收器未就绪（LAUNCH 超时）"
            case .notConnected: return "未连接设备"
            }
        }
    }

    /// 推流：建连 → 拉起默认媒体接收器 → LOAD 直链
    func cast(ip: String, stream: StreamInfo, title: String) async throws {
        stopSession()   // 已有会话先静默关闭
        let connection = try await connect(ip: ip)
        self.conn = connection

        // 1. 虚拟连接 + 拉起默认媒体接收器
        send(namespace: "urn:x-cast:com.google.cast.tp.connection",
             payload: #"{"type":"CONNECT"}"#)
        send(namespace: "urn:x-cast:com.google.cast.receiver",
             payload: #"{"type":"LAUNCH","appId":"CC1AD845","requestId":"# + "\(nextRequestID())}")

        // 2. 轮询 RECEIVER_STATUS 等待 transportId
        let deadline = Date().addingTimeInterval(12)
        while currentTransportID() == nil && Date() < deadline {
            send(namespace: "urn:x-cast:com.google.cast.receiver",
                 payload: #"{"type":"GET_STATUS","requestId":"# + "\(nextRequestID())}")
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        guard let tid = currentTransportID() else {
            stopSession()
            throw CastError.receiverNotReady
        }

        // 3. 虚拟连接到应用会话，再 LOAD 媒体
        send(namespace: "urn:x-cast:com.google.cast.tp.connection",
             destination: tid, payload: #"{"type":"CONNECT"}"#)
        let media: [String: Any] = [
            "type": "LOAD",
            "requestId": nextRequestID(),
            "currentTime": 0,
            "autoplay": true,
            "media": [
                "contentId": stream.url.absoluteString,
                "streamType": "BUFFERED",
                "contentType": Self.mimeType(container: stream.container),
                "metadata": ["metadataType": 0, "title": title],
            ],
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: media)
        send(namespace: "urn:x-cast:com.google.cast.media",
             destination: tid, payload: String(decoding: payloadData, as: UTF8.self))

        // 4. 心跳保活
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                self?.send(namespace: "urn:x-cast:com.google.cast.tp.heartbeat",
                           payload: #"{"type":"PING"}"#)
            }
        }
    }

    // MARK: 远程控制（投屏遥控用）

    private func mediaCommand(_ type: String, extra: [String: Any] = [:]) {
        guard let tid = currentTransportID() else { return }
        var payload: [String: Any] = ["type": type, "requestId": nextRequestID()]
        if let mid = statusSnapshot()?.mediaSessionId, mid > 0 { payload["mediaSessionId"] = mid }
        payload.merge(extra) { _, new in new }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        send(namespace: "urn:x-cast:com.google.cast.media",
             destination: tid, payload: String(decoding: data, as: UTF8.self))
    }

    func pause() { mediaCommand("PAUSE") }
    func resume() { mediaCommand("PLAY") }

    func seek(to seconds: Double) {
        mediaCommand("SEEK", extra: ["currentTime": seconds])
    }

    /// 音量 0-1（receiver 通道 SET_VOLUME）
    func setVolume(level: Double) {
        let payload: [String: Any] = [
            "type": "SET_VOLUME",
            "requestId": nextRequestID(),
            "volume": ["level": min(max(level, 0), 1)],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        send(namespace: "urn:x-cast:com.google.cast.receiver",
             payload: String(decoding: data, as: UTF8.self))
    }

    /// 断开：STOP 媒体 + CLOSE 虚拟连接 + 关 socket
    func stopSession() {
        if let tid = currentTransportID() {
            send(namespace: "urn:x-cast:com.google.cast.media",
                 destination: tid, payload: #"{"type":"STOP","mediaSessionId":0,"requestId":0}"#)
            send(namespace: "urn:x-cast:com.google.cast.tp.connection",
                 destination: tid, payload: #"{"type":"CLOSE"}"#)
        }
        heartbeatTask?.cancel()
        heartbeatTask = nil
        lock.lock()
        transportID = nil
        rxBuffer = Data()
        lock.unlock()
        conn?.stateUpdateHandler = nil
        conn?.cancel()
        conn = nil
    }

    // MARK: 连接与收发

    private func connect(ip: String) async throws -> NWConnection {
        let tls = NWProtocolTLS.Options()
        // Chromecast 自签证书：跳过校验
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
            complete(true)
        }, DispatchQueue.global())
        let params = NWParameters(tls: tls)
        let connection = NWConnection(host: NWEndpoint.Host(ip), port: 8009, using: params)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if !resumed { resumed = true; self?.startReceiveLoop(connection); cont.resume() }
                case .failed(let error):
                    if !resumed { resumed = true; cont.resume(throwing: error) }
                case .cancelled:
                    if !resumed { resumed = true; cont.resume(throwing: CastError.connectFailed) }
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "luplay.castv2.io"))
        }
        return connection
    }

    private func startReceiveLoop(_ connection: NWConnection) {
        receiveNext(connection)
    }

    private func receiveNext(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.lock()
                self.rxBuffer.append(data)
                let messages = self.drainFramesLocked()
                self.lock.unlock()
                messages.forEach(self.handle)
            }
            if error == nil && !isComplete {
                self.receiveNext(connection)
            } else {
                // 连接断开：清空会话状态
                self.lock.lock()
                self.transportID = nil
                self.lock.unlock()
            }
        }
    }

    /// 从缓冲拆帧（4 字节大端长度前缀 + protobuf 消息体）；调用方需持锁
    private func drainFramesLocked() -> [(namespace: String, payload: String)] {
        var messages: [(namespace: String, payload: String)] = []
        while rxBuffer.count >= 4 {
            let length = Int(rxBuffer[rxBuffer.startIndex]) << 24 | Int(rxBuffer[rxBuffer.startIndex + 1]) << 16
                | Int(rxBuffer[rxBuffer.startIndex + 2]) << 8 | Int(rxBuffer[rxBuffer.startIndex + 3])
            guard rxBuffer.count >= 4 + length, length > 0 else { break }
            let frame = rxBuffer.subdata(in: (rxBuffer.startIndex + 4)..<(rxBuffer.startIndex + 4 + length))
            rxBuffer.removeFirst(4 + length)
            if let msg = Self.decode(frame) { messages.append(msg) }
        }
        return messages
    }

    private func handle(_ message: (namespace: String, payload: String)) {
        switch message.namespace {
        case "urn:x-cast:com.google.cast.receiver":
            if let tid = Self.transportID(in: message.payload) {
                lock.lock()
                transportID = tid
                lock.unlock()
            }
        case "urn:x-cast:com.google.cast.media":
            if let status = Self.mediaStatus(in: message.payload) {
                lock.lock()
                lastStatus = status
                lock.unlock()
            }
        default:
            break
        }
    }

    private func send(namespace: String, destination: String = "receiver-0", payload: String) {
        guard let conn else { return }
        let frame = Self.frame(source: "sender-0", destination: destination,
                               namespace: namespace, payload: payload)
        conn.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func currentTransportID() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return transportID
    }

    private func nextRequestID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        requestID += 1
        return requestID
    }

    private static func mimeType(container: String) -> String {
        switch container.lowercased() {
        case "mkv", "matroska": return "video/x-matroska"
        case "webm": return "video/webm"
        case "hls", "m3u8": return "application/x-mpegURL"
        case "avi": return "video/x-msvideo"
        case "flv": return "video/x-flv"
        default: return "video/mp4"
        }
    }

    // MARK: - CastChannel protobuf（手写编解码，仅覆盖 CastMessage 所需字段）

    private static func frame(source: String, destination: String,
                              namespace: String, payload: String) -> Data {
        var body = Data()
        body.append(taggedVarint(1, 0))                    // protocol_version = CASTV2_1_0
        body.append(taggedBytes(2, Data(source.utf8)))     // source_id
        body.append(taggedBytes(3, Data(destination.utf8)))// destination_id
        body.append(taggedBytes(4, Data(namespace.utf8)))  // namespace
        body.append(taggedVarint(5, 0))                    // payload_type = STRING
        body.append(taggedBytes(6, Data(payload.utf8)))    // payload_utf8
        var out = Data()
        let len = UInt32(body.count)
        for shift in stride(from: 24, through: 0, by: -8) {   // 4 字节大端长度前缀
            out.append(UInt8((len >> UInt32(shift)) & 0xFF))
        }
        out.append(body)
        return out
    }

    private static func taggedVarint(_ field: UInt8, _ value: UInt8) -> Data {
        var out = Data([field << 3 | 0])   // wiretype 0 = varint
        out.append(value)
        return out
    }

    private static func taggedBytes(_ field: UInt8, _ bytes: Data) -> Data {
        var out = Data([field << 3 | 2])   // wiretype 2 = length-delimited
        var length = bytes.count
        while true {                        // varint 编码长度
            if length < 0x80 {
                out.append(UInt8(length))
                break
            }
            out.append(UInt8(length & 0x7F | 0x80))
            length >>= 7
        }
        out.append(bytes)
        return out
    }

    struct CastMessage {
        let namespace: String
        let payload: String
    }

    /// 最小 protobuf 解码：只提取 namespace(field 4) 与 payload_utf8(field 6)
    private static func decode(_ data: Data) -> CastMessage? {
        let bytes = [UInt8](data)
        var i = 0
        var namespace: String?
        var payload: String?
        while i < bytes.count {
            let tag = bytes[i]
            let field = tag >> 3
            let wire = tag & 0x07
            i += 1
            switch wire {
            case 0: // varint
                while i < bytes.count && bytes[i] & 0x80 != 0 { i += 1 }
                i += 1
            case 1: i += 8          // 64-bit
            case 5: i += 4          // 32-bit
            case 2:                 // length-delimited
                var length = 0
                var shift = 0
                while i < bytes.count {
                    let b = bytes[i]
                    i += 1
                    length |= Int(b & 0x7F) << shift
                    if b & 0x80 == 0 { break }
                    shift += 7
                }
                guard i + length <= bytes.count else { return nil }
                let chunk = Array(bytes[i..<(i + length)])
                if field == 4 { namespace = String(decoding: chunk, as: UTF8.self) }
                if field == 6 { payload = String(decoding: chunk, as: UTF8.self) }
                i += length
            default:
                return nil
            }
        }
        guard let namespace, let payload else { return nil }
        return CastMessage(namespace: namespace, payload: payload)
    }

    private static func transportID(in payload: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              obj["type"] as? String == "RECEIVER_STATUS",
              let status = obj["status"] as? [String: Any],
              let apps = status["applications"] as? [[String: Any]]
        else { return nil }
        return apps.first?["transportId"] as? String
    }

    /// MEDIA_STATUS → 遥控面板状态（首条 status；duration 在 media 节点里）
    private static func mediaStatus(in payload: String) -> MediaStatus? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              obj["type"] as? String == "MEDIA_STATUS",
              let list = obj["status"] as? [[String: Any]],
              let first = list.first
        else { return nil }
        let media = first["media"] as? [String: Any]
        return MediaStatus(
            playerState: first["playerState"] as? String ?? "IDLE",
            currentTime: first["currentTime"] as? Double ?? 0,
            duration: (media?["duration"] as? Double) ?? 0,
            mediaSessionId: first["mediaSessionId"] as? Int ?? 0
        )
    }

    // MARK: - SSDP socket（与 DLNAClient 同款 BSD 实现）

    private static func openSocket() -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return -1 }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    private static func sendSSDP(_ fd: Int32, searchTarget: String) {
        let message = """
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        MAN: "ssdp:discover"\r
        MX: 2\r
        ST: \(searchTarget)\r
        \r

        """
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(1900).bigEndian
        guard inet_pton(AF_INET, "239.255.255.250", &addr.sin_addr) == 1 else { return }
        withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                message.withCString { cstr in
                    _ = sendto(fd, cstr, strlen(cstr), 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private static func waitForData(_ fd: Int32, seconds: Double) -> Bool {
        var set = fd_set()
        FD_ZERO(&set)
        FD_SET(fd, &set)
        let tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds.truncatingRemainder(dividingBy: 1)) * 1_000_000))
        return select(fd + 1, &set, nil, nil, &tv) > 0
    }
}

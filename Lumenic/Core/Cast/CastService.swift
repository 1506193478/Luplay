import Foundation

// MARK: - 投屏服务（方案 §7）
// DLNA：SSDP 扫描 + AVTransport 推直链；
// Chromecast：DIAL/SSDP 发现 + CastV2（TLS socket + protobuf + JSON）推直链；
// AirPlay：系统路由选择器承担（AVRoutePickerView），不走此处扫描。

struct CastDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let kind: Kind
    enum Kind { case airplay, dlna, chromecast }

    var kindLabel: String {
        switch kind {
        case .airplay: return "AirPlay"
        case .dlna: return "DLNA"
        case .chromecast: return "Chromecast"
        }
    }
}

protocol CastServiceProtocol {
    /// 扫描同一 Wi-Fi 下的设备（对标投屏面板“正在搜索同一 Wi-Fi 下的设备...”）
    func scan() async -> [CastDevice]
    /// 推流：mpv 播放 MKV 时走 DLNA 推直链；AVPlayer 场景优先 AirPlay
    func cast(to device: CastDevice, stream: StreamInfo, title: String) async throws
    func disconnect() async
}

final class CastService: CastServiceProtocol, ObservableObject {
    @Published var devices: [CastDevice] = []
    @Published var isScanning = false
    @Published private(set) var connectedDevice: CastDevice?
    @Published private(set) var lastError: String?
    /// 远端播放状态（遥控面板：进度/时长/播放中），轮询刷新
    @Published private(set) var remoteStatus: RemoteStatus?

    struct RemoteStatus {
        let position: Double
        let duration: Double
        let isPlaying: Bool
    }

    private let dlna = DLNAClient()
    /// deviceId → SOAP 端点（AVTransport + RenderingControl）
    private var endpoints: [String: DLNAClient.Endpoints] = [:]
    private let castv2 = CastV2Client()
    /// deviceId → Chromecast IP（TLS 8009 直连）
    private var chromecastIPs: [String: String] = [:]
    private var pollTask: Task<Void, Never>?

    func scan() async -> [CastDevice] {
        isScanning = true
        defer { isScanning = false }
        // DLNA 与 Chromecast 并行扫描（各自的 SSDP socket）
        async let dlnaFound = dlna.discover()
        async let ccFound = castv2.discover()
        let (dlnaList, ccList) = await (dlnaFound, ccFound)

        var result: [CastDevice] = []
        for device in dlnaList {
            guard let described = await dlna.describe(device: device) else { continue }
            endpoints[device.usn] = described.endpoints
            result.append(CastDevice(id: device.usn, name: described.name, kind: .dlna))
        }
        for device in ccList {
            let id = "chromecast-\(device.ip)"
            chromecastIPs[id] = device.ip
            result.append(CastDevice(id: id, name: device.name, kind: .chromecast))
        }
        devices = result.sorted { $0.name < $1.name }
        return devices
    }

    func cast(to device: CastDevice, stream: StreamInfo, title: String) async throws {
        do {
            switch device.kind {
            case .dlna:
                guard let ep = endpoints[device.id] else {
                    throw DLNAClient.CastError.deviceRejected(code: 0)  // 设备信息过期，需重新扫描
                }
                try await dlna.cast(url: stream.url, title: title, controlURL: ep.avTransport)
            case .chromecast:
                guard let ip = chromecastIPs[device.id] else {
                    throw CastV2Client.CastError.notConnected
                }
                try await castv2.cast(ip: ip, stream: stream, title: title)
            case .airplay:
                throw DLNAClient.CastError.deviceRejected(code: -1)  // AirPlay 走系统路由选择器
            }
            connectedDevice = device
            lastError = nil
            startPolling(device)
        } catch {
            lastError = "推流失败：\(error)"
            throw error
        }
    }

    // MARK: 远程控制（面板遥控区）

    func pauseRemote() {
        guard let device = connectedDevice else { return }
        switch device.kind {
        case .dlna:
            if let ep = endpoints[device.id] { Task { try? await dlna.pause(controlURL: ep.avTransport) } }
        case .chromecast:
            castv2.pause()
        case .airplay:
            break
        }
    }

    func playRemote() {
        guard let device = connectedDevice else { return }
        switch device.kind {
        case .dlna:
            if let ep = endpoints[device.id] { Task { try? await dlna.resume(controlURL: ep.avTransport) } }
        case .chromecast:
            castv2.resume()
        case .airplay:
            break
        }
    }

    func seekRemote(to seconds: Double) {
        guard let device = connectedDevice else { return }
        switch device.kind {
        case .dlna:
            if let ep = endpoints[device.id] {
                Task { try? await dlna.seek(to: seconds, controlURL: ep.avTransport) }
            }
        case .chromecast:
            castv2.seek(to: seconds)
        case .airplay:
            break
        }
    }

    /// 音量 0-100
    func setRemoteVolume(_ percent: Double) {
        guard let device = connectedDevice else { return }
        switch device.kind {
        case .dlna:
            if let ep = endpoints[device.id], let rc = ep.renderingControl {
                Task { try? await dlna.setVolume(Int(percent.rounded()), renderingControlURL: rc) }
            }
        case .chromecast:
            castv2.setVolume(level: percent / 100)
        case .airplay:
            break
        }
    }

    /// 初始音量（0-100），用于遥控滑杆初值
    func remoteVolume() async -> Double? {
        guard let device = connectedDevice else { return nil }
        switch device.kind {
        case .dlna:
            if let ep = endpoints[device.id], let rc = ep.renderingControl,
               let v = await dlna.volume(renderingControlURL: rc) {
                return Double(v)
            }
            return nil
        case .chromecast:
            return nil   // Cast 音量回读未实现，滑杆用默认值
        case .airplay:
            return nil
        }
    }

    // MARK: 远端状态轮询（2s 一次；连接断开自动停止）

    private func startPolling(_ device: CastDevice) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled, let self,
                  self.connectedDevice?.id == device.id {
                let status: RemoteStatus?
                switch device.kind {
                case .dlna:
                    if let ep = self.endpoints[device.id],
                       let info = await self.dlna.positionInfo(controlURL: ep.avTransport) {
                        status = RemoteStatus(position: info.position, duration: info.duration,
                                              isPlaying: info.isPlaying)
                    } else {
                        status = nil
                    }
                case .chromecast:
                    if let s = self.castv2.statusSnapshot() {
                        status = RemoteStatus(position: s.currentTime, duration: s.duration,
                                              isPlaying: s.playerState == "PLAYING")
                    } else {
                        status = nil
                    }
                case .airplay:
                    status = nil
                }
                if let status { self.remoteStatus = status }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func disconnect() async {
        pollTask?.cancel()
        pollTask = nil
        remoteStatus = nil
        if let device = connectedDevice {
            switch device.kind {
            case .dlna:
                if let ep = endpoints[device.id] {
                    try? await dlna.stop(controlURL: ep.avTransport)
                }
            case .chromecast:
                castv2.stopSession()
            case .airplay:
                break
            }
        }
        connectedDevice = nil
    }
}

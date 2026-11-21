import Foundation

// MARK: - 投屏服务协议（方案 §7）

struct CastDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let kind: Kind
    enum Kind { case airplay, dlna, chromecast }
}

protocol CastServiceProtocol {
    /// 扫描同一 Wi-Fi 下的设备（对标投屏面板“正在搜索同一 Wi-Fi 下的设备...”）
    func scan() async -> [CastDevice]
    /// 推流：mpv 播放 MKV 时走 DLNA 推直链；AVPlayer 场景优先 AirPlay
    func cast(to device: CastDevice, stream: StreamInfo) async throws
    func disconnect() async
}

final class CastService: CastServiceProtocol, ObservableObject {
    @Published var devices: [CastDevice] = []
    @Published var isScanning = false

    func scan() async -> [CastDevice] {
        isScanning = true
        defer { isScanning = false }
        // M6：DLNA 用 SSDP M-SEARCH 发现（CyberLink for Swift）；
        // AirPlay 由系统路由选择器承担，不走此处。
        devices = []
        return []
    }

    func cast(to device: CastDevice, stream: StreamInfo) async throws {
        // M6：DLNA AVTransport SetAVTransportURI → Play
    }

    func disconnect() async {}
}

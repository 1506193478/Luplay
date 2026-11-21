import Foundation

// MARK: - 投屏服务（方案 §7）
// DLNA：SSDP 扫描 + AVTransport 推直链；
// AirPlay：系统路由选择器承担（AVRoutePickerView），不走此处扫描。

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
    func cast(to device: CastDevice, stream: StreamInfo, title: String) async throws
    func disconnect() async
}

final class CastService: CastServiceProtocol, ObservableObject {
    @Published var devices: [CastDevice] = []
    @Published var isScanning = false
    @Published private(set) var connectedDevice: CastDevice?
    @Published private(set) var lastError: String?

    private let dlna = DLNAClient()
    /// deviceId → AVTransport controlURL
    private var controlURLs: [String: URL] = [:]

    func scan() async -> [CastDevice] {
        isScanning = true
        defer { isScanning = false }
        let found = await dlna.discover()
        var result: [CastDevice] = []
        for device in found {
            guard let described = await dlna.describe(device: device) else { continue }
            controlURLs[device.usn] = described.controlURL
            result.append(CastDevice(id: device.usn, name: described.name, kind: .dlna))
        }
        devices = result.sorted { $0.name < $1.name }
        return devices
    }

    func cast(to device: CastDevice, stream: StreamInfo, title: String) async throws {
        guard let control = controlURLs[device.id] else {
            throw DLNAClient.CastError.deviceRejected(code: 0)  // 设备信息过期，需重新扫描
        }
        do {
            try await dlna.cast(url: stream.url, title: title, controlURL: control)
            connectedDevice = device
            lastError = nil
        } catch {
            lastError = "推流失败：\(error)"
            throw error
        }
    }

    func disconnect() async {
        if let device = connectedDevice, let control = controlURLs[device.id] {
            try? await dlna.stop(controlURL: control)
        }
        connectedDevice = nil
    }
}

import Foundation
import CoreMedia

// MARK: - 播放内核协议（方案 §3.1）

enum EngineKind: String, Codable { case avplayer, mpv }

struct EngineCapabilities: OptionSet {
    let rawValue: Int
    static let pip = Self(rawValue: 1 << 0)
    static let airplay = Self(rawValue: 1 << 1)
    static let dolbyVision = Self(rawValue: 1 << 2)
    static let assSubtitle = Self(rawValue: 1 << 3)
    static let pgsSubtitle = Self(rawValue: 1 << 4)
}

struct PlayableItem {
    let url: URL
    let headers: [String: String]
    let engine: EngineKind
    let startPosition: TimeInterval
}

struct PlaybackTick {
    let position: TimeInterval
    let duration: TimeInterval
    let buffered: TimeInterval
    let fps: Double?
    let bitrateBps: Double?
}

struct TrackInfo: Identifiable, Hashable {
    enum Kind { case audio, subtitle, video }
    let id: String
    let kind: Kind
    let name: String
    let language: String?
    let isDefault: Bool
}

protocol PlayerEngine: AnyObject {
    var capabilities: EngineCapabilities { get }
    var tickStream: AsyncStream<PlaybackTick> { get }

    func load(_ item: PlayableItem) async throws
    func play()
    func pause()
    var isPlaying: Bool { get }
    func seek(to seconds: TimeInterval)
    func setRate(_ rate: Double)

    func availableTracks() -> [TrackInfo]
    func selectAudio(_ id: String)
    func selectSubtitle(_ id: String?)
    func loadExternalSubtitle(_ url: URL)

    /// 渲染层视图（AVPlayerLayer / mpv Metal）
    func makeRenderView() -> Any
}

// MARK: - 内核选择策略（方案 §3.4）

enum EngineSelector {
    /// 按片源信息推荐内核；用户设置可覆盖
    static func recommend(container: String, codec: String?, hdr: String?) -> EngineKind {
        let c = container.lowercased()
        if c == "m3u8" || c == "hls" { return .avplayer }
        if c == "mp4" || c == "webm" { return .avplayer }
        if let h = hdr, h.contains("杜比视界") || h.contains("Dolby Vision") {
            // P5 需系统管线渲染，避免 mpv 色偏；M4 校验 profile 后细化
            return .avplayer
        }
        return .mpv
    }
}

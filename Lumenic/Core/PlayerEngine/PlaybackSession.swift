import Foundation
import SwiftUI

// MARK: - 引擎工厂

enum EngineFactory {
    @MainActor
    static func make(_ kind: EngineKind) -> PlayerEngine {
        switch kind {
        case .avplayer: return AVPlayerEngine()
        case .mpv: return MPVEngine()
        }
    }
}

// MARK: - 播放会话（方案 §4.3：换源/换内核不丢进度）

@MainActor
final class PlaybackSession: ObservableObject {
    @Published private(set) var tick: PlaybackTick?
    @Published private(set) var engineKind: EngineKind
    @Published var rate: Double = 1.0
    @Published private(set) var isPlaying = false
    @Published private(set) var tracks: [TrackInfo] = []   // 音轨/字幕轨（轨道面板用）

    private(set) var engine: PlayerEngine
    private var item: PlayableItem?
    private var mediaKey: String   // 进度存储 key（tmdbKey 或 URL 哈希）
    private var database: AppDatabase
    private var tickTask: Task<Void, Never>?

    init(kind: EngineKind, mediaKey: String, database: AppDatabase) {
        self.engineKind = kind
        self.engine = EngineFactory.make(kind)
        self.mediaKey = mediaKey
        self.database = database
    }

    /// 进度存储 key（片头片尾标记等共用）
    var storageKey: String { mediaKey }

    /// UI 层拿不到 env 时先用内存库初始化，进场后重绑真实库（保证进度落盘）
    func useDatabase(_ db: AppDatabase) { database = db }

    /// 从存储恢复进度并加载
    func start(_ item: PlayableItem) async {
        self.item = item
        let restored = (try? database.progress(forKey: mediaKey))?.position ?? 0
        let withPosition = PlayableItem(url: item.url, headers: item.headers,
                                        engine: item.engine,
                                        startPosition: max(item.startPosition, restored))
        try? await engine.load(withPosition)
        engine.play()
        isPlaying = true
        consumeTicks()
        refreshTracks()
    }

    /// 换内核（保留当前进度）：mpv→AVPlayer 转投桥也走这里
    func switchEngine(to kind: EngineKind) async {
        guard kind != engineKind, let item else { return }
        let position = tick?.position ?? 0
        engine.pause()
        engine = EngineFactory.make(kind)
        engineKind = kind
        let moved = PlayableItem(url: item.url, headers: item.headers,
                                 engine: kind, startPosition: position)
        try? await engine.load(moved)
        engine.setRate(rate)
        engine.play()
        isPlaying = true
        consumeTicks()
        refreshTracks()
    }

    /// 换片源（同内核重载新地址，进度不丢；M4 来源对比面板用）
    func switchSource(to newItem: PlayableItem) async {
        let position = tick?.position ?? 0
        engine.pause()
        let moved = PlayableItem(url: newItem.url, headers: newItem.headers,
                                 engine: engineKind, startPosition: position)
        try? await engine.load(moved)
        engine.setRate(rate)
        engine.play()
        isPlaying = true
        consumeTicks()
        refreshTracks()
        item = newItem
    }

    func play() { engine.play(); isPlaying = true }
    func pause() { engine.pause(); isPlaying = false }
    func seek(to seconds: TimeInterval) { engine.seek(to: seconds) }
    func setRate(_ r: Double) { rate = r; engine.setRate(r) }
    func togglePiP() {
        if let av = engine as? AVPlayerEngine { av.togglePiP() }
    }

    /// 字幕样式/时序属性透传（mpv 生效）
    func applySubtitleOption(name: String, value: String) {
        engine.setSubtitleOption(name: name, value: value)
    }

    // MARK: 轨道选择（音轨/字幕轨/外挂字幕）

    /// 重新读取引擎轨道列表（加载完成后 + 面板打开时调用）
    func refreshTracks() {
        tracks = engine.availableTracks()
    }

    func selectAudio(_ id: String) {
        engine.selectAudio(id)
        refreshTracks()
    }

    /// nil = 关闭字幕
    func selectSubtitle(_ id: String?) {
        engine.selectSubtitle(id)
        refreshTracks()
    }

    /// 外挂字幕（mpv 内核生效；AVPlayer 无此能力）
    func loadExternalSubtitle(_ url: URL) {
        engine.loadExternalSubtitle(url)
        refreshTracks()
    }

    /// 退出播放器时保存进度
    func close() {
        if let tick, tick.position > 3 {
            // 集级进度：从 mediaKey 的集标签解析 season/episode（"好东西|第2集" / "…|S01E02"）
            let label = mediaKey.contains("|")
                ? mediaKey.split(separator: "|", maxSplits: 1).last.map(String.init) ?? ""
                : ""
            let (season, episode) = EpisodeProgressParser.parse(label)
            let progress = PlaybackProgress(tmdbKey: mediaKey, season: season, episode: episode,
                                            position: tick.position, duration: tick.duration,
                                            updatedAt: Date())
            try? database.save(progress: progress)
        }
        tickTask?.cancel()
        engine.pause()
        isPlaying = false
    }

    private func consumeTicks() {
        tickTask?.cancel()
        tick = nil
        let stream = engine.tickStream
        tickTask = Task { [weak self] in
            for await t in stream {
                guard let self, !Task.isCancelled else { return }
                self.tick = t
            }
        }
    }
}

// MARK: - 集级进度解析（"S01E02"→(1,2)；"第2集"→(1,2)；其他→(1,1)）

enum EpisodeProgressParser {
    static func parse(_ label: String) -> (season: Int, episode: Int) {
        let ns = label as NSString
        if let re = try? NSRegularExpression(pattern: #"(?i)s(\d{1,2})[\s._-]*e(\d{1,4})"#),
           let m = re.firstMatch(in: label, range: NSRange(location: 0, length: ns.length)),
           m.numberOfRanges >= 3 {
            return (Int(ns.substring(with: m.range(at: 1))) ?? 1,
                    Int(ns.substring(with: m.range(at: 2))) ?? 1)
        }
        if let re = try? NSRegularExpression(pattern: #"第\s*(\d{1,4})\s*[集话話]"#),
           let m = re.firstMatch(in: label, range: NSRange(location: 0, length: ns.length)),
           m.numberOfRanges >= 2 {
            return (1, Int(ns.substring(with: m.range(at: 1))) ?? 1)
        }
        return (1, 1)
    }
}

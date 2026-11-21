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

    /// 从存储恢复进度并加载
    func start(_ item: PlayableItem) async {
        self.item = item
        let restored = (try? database.progress(forKey: mediaKey))?.position ?? 0
        let withPosition = PlayableItem(url: item.url, headers: item.headers,
                                        engine: item.engine,
                                        startPosition: max(item.startPosition, restored))
        try? await engine.load(withPosition)
        engine.play()
        consumeTicks()
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
        consumeTicks()
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
        consumeTicks()
        item = newItem
    }

    func play() { engine.play() }
    func pause() { engine.pause() }
    var isPlaying: Bool { engine.isPlaying }
    func seek(to seconds: TimeInterval) { engine.seek(to: seconds) }
    func setRate(_ r: Double) { rate = r; engine.setRate(r) }
    func togglePiP() {
        if let av = engine as? AVPlayerEngine { av.togglePiP() }
    }

    /// 退出播放器时保存进度
    func close() {
        if let tick, tick.position > 3 {
            let progress = PlaybackProgress(tmdbKey: mediaKey, season: 1, episode: 1,
                                            position: tick.position, duration: tick.duration,
                                            updatedAt: Date())
            try? database.save(progress: progress)
        }
        tickTask?.cancel()
        engine.pause()
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

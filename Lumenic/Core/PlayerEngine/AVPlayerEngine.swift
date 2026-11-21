import Foundation
import AVFoundation
import MediaPlayer
import UIKit

/// AVPlayer 内核：HLS/MP4、杜比视界系统管线、PiP、AirPlay、锁屏遥控。
/// headers 注入走自定义 scheme + AVAssetResourceLoaderDelegate。
final class AVPlayerEngine: NSObject, PlayerEngine {
    static let customScheme = "lumenic"

    let player = AVPlayer()
    private(set) lazy var pipController: AVPictureInPictureController? = {
        AVPictureInPictureController(playerLayer: layerHost.playerLayer)
    }()

    private var timeObserver: Any?
    private var tickContinuation: AsyncStream<PlaybackTick>.Continuation?
    private var assetLoader: HeaderedResourceLoader?
    private var remoteCommandTargets: [Any] = []

    var capabilities: EngineCapabilities { [.pip, .airplay, .dolbyVision] }

    lazy var tickStream: AsyncStream<PlaybackTick> = AsyncStream { continuation in
        self.tickContinuation = continuation
    }

    override init() {
        self.layerHost = LayerHostingView()
        super.init()
        layerHost.player = player
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
        setupRemoteCommands()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    // MARK: - 加载

    func load(_ item: PlayableItem) async throws {
        let asset: AVURLAsset
        if item.headers.isEmpty {
            asset = AVURLAsset(url: item.url)
        } else {
            // 换成自定义 scheme，由 delegate 补 headers 后转发原始请求
            asset = AVURLAsset(url: Self.rewrite(item.url))
            let loader = HeaderedResourceLoader(headers: item.headers, originalScheme: item.url.scheme ?? "https")
            asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "lumenic.loader"))
            assetLoader = loader // 保活
        }
        let playerItem = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: playerItem)
        if item.startPosition > 0 {
            await player.seek(to: CMTime(seconds: item.startPosition, preferredTimescale: 600))
        }
        observeTime()
        updateNowPlaying()
    }

    /// https://host/path → lumenic://https/host/path（保留原 scheme 供还原）
    static func rewrite(_ url: URL) -> URL {
        var comps = URLComponents()
        comps.scheme = customScheme
        comps.host = url.scheme
        comps.path = "/" + url.absoluteString
        return comps.url!
    }

    static func restore(_ url: URL) -> URL? {
        guard url.scheme == customScheme, url.host != nil else { return url }
        return URL(string: String(url.path.dropFirst()))
    }

    // MARK: - 控制

    func play() { player.play(); updateNowPlaying() }
    func pause() { player.pause(); updateNowPlaying() }
    func seek(to seconds: TimeInterval) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }
    func setRate(_ rate: Double) {
        player.rate = rate == 1.0 ? Float(rate) : Float(rate) // 保持 play 状态变速
        if rate > 0 { player.play() }
        updateNowPlaying()
    }

    var isPlaying: Bool { player.rate > 0 }

    // MARK: - 轨道

    func availableTracks() -> [TrackInfo] {
        guard let item = player.currentItem else { return [] }
        var result: [TrackInfo] = []
        let asset = item.asset
        let groups: [(AVMediaSelectionGroup?, TrackInfo.Kind)] = [
            (asset.mediaSelectionGroup(for: .audible), .audio),
            (asset.mediaSelectionGroup(for: .legible), .subtitle),
        ]
        for (group, kind) in groups {
            guard let group else { continue }
            for (i, opt) in group.options.enumerated() {
                result.append(TrackInfo(id: "\(kind == .audio ? "a" : "s")\(i)",
                                        kind: kind,
                                        name: opt.displayName,
                                        language: opt.extendedLanguageTag,
                                        isDefault: group.defaultOption == opt))
            }
        }
        return result
    }

    func selectAudio(_ id: String) { selectOption(id: id, type: .audible) }
    func selectSubtitle(_ id: String?) {
        guard let item = player.currentItem else { return }
        guard let id else {
            item.select(nil, in: item.asset.mediaSelectionGroup(for: .legible))
            return
        }
        selectOption(id: id, type: .legible)
    }

    private func selectOption(id: String, type: AVMediaType) {
        guard let item = player.currentItem,
              let group = item.asset.mediaSelectionGroup(for: type) else { return }
        let index = Int(id.dropFirst()) ?? 0
        guard index < group.options.count else { return }
        item.select(group.options[index], in: group)
    }

    func loadExternalSubtitle(_ url: URL) {
        // AVPlayer 不支持外挂字幕，UI 层应提示切换 mpv 内核
    }

    // MARK: - PiP

    func togglePiP() {
        guard let pip = pipController else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }

    // MARK: - 渲染

    func makeRenderView() -> Any { layerHost }

    // MARK: - 内部

    private let layerHost: LayerHostingView

    private func observeTime() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self, let item = self.player.currentItem else { return }
            self.tickContinuation?.yield(PlaybackTick(
                position: time.seconds,
                duration: item.duration.seconds.isFinite ? item.duration.seconds : 0,
                buffered: item.loadedTimeRanges.first?.timeRangeValue.end.seconds ?? 0,
                fps: nil,
                bitrateBps: nil
            ))
        }
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.player.play(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.player.pause(); return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime)
            return .success
        }
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [:]
        if let item = player.currentItem {
            info[MPMediaItemPropertyDuration] = item.duration.seconds
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime().seconds
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.rate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

// MARK: - headers 注入 loader

final class HeaderedResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let headers: [String: String]
    private let originalScheme: String

    init(headers: [String: String], originalScheme: String) {
        self.headers = headers
        self.originalScheme = originalScheme
        super.init()
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = AVPlayerEngine.restore(loadingRequest.request.url) else { return false }
        var request = URLRequest(url: url)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("Luplay/1.0", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let http = response as? HTTPURLResponse, let data, error == nil else {
                loadingRequest.finishLoading(with: error)
                return
            }
            if let contentReq = loadingRequest.contentInformationRequest {
                contentReq.contentType = http.mimeType
                contentReq.contentLength = Int64(data.count)
                contentReq.isByteRangeAccessSupported = false
            }
            loadingRequest.dataRequest?.respond(with: data)
            loadingRequest.finishLoading()
        }.resume()
        return true
    }
}

// MARK: - 渲染宿主

final class LayerHostingView: UIView {
    let layer0 = AVPlayerLayer()
    var player: AVPlayer? {
        didSet { layer0.player = player }
    }
    var playerLayer: AVPlayerLayer { layer0 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(layer0)
        layer0.videoGravity = .resizeAspect
        backgroundColor = .black
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        layer0.frame = bounds
    }
}

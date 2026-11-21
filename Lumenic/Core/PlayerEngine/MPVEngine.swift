import Foundation
import UIKit
import GLKit
import Darwin

#if canImport(MPVKit)
import MPVKit
#endif

/// mpv 内核（libmpv）：MKV/ASS/PGS/HEVC10bit 通吃，VideoToolbox 硬解。
/// 渲染走 OpenGL ES + mpv_render_context（首编如模块名有出入，改 import 行即可）。
final class MPVEngine: NSObject, PlayerEngine {
    var capabilities: EngineCapabilities { [.assSubtitle, .pgsSubtitle] }

    lazy var tickStream: AsyncStream<PlaybackTick> = AsyncStream { continuation in
        self.tickContinuation = continuation
    }

    static var isAvailable: Bool {
        #if canImport(MPVKit)
        return true
        #else
        return false
        #endif
    }

    // MARK: - 状态

    #if canImport(MPVKit)
    private var handle: OpaquePointer?
    private var renderContext: OpaquePointer?
    #endif
    private var tickContinuation: AsyncStream<PlaybackTick>.Continuation?
    private var eventQueue = DispatchQueue(label: "lumenic.mpv.events")
    private var eventLoopRunning = false

    // 属性缓存（事件线程写，主线程读）
    private var cachedPosition: Double = 0
    private var cachedDuration: Double = 0
    private var cachedBuffered: Double = 0
    private var cachedFPS: Double?
    private var cachedBitrate: Double?

    // MARK: - 生命周期

    override init() {
        super.init()
        #if canImport(MPVKit)
        guard let h = mpv_create() else { return }
        handle = h
        mpv_set_option_string(h, "hwdec", "videotoolbox")
        mpv_set_option_string(h, "vo", "libmpv")
        mpv_set_option_string(h, "cache", "yes")
        mpv_set_option_string(h, "demuxer-max-bytes", "256MiB")   // 60s 预读缓冲（方案 §9.6）
        mpv_set_option_string(h, "keep-open", "yes")
        mpv_set_option_string(h, "force-window", "no")
        mpv_set_option_string(h, "audio-display", "no")
        mpv_set_option_string(h, "sub-auto", "fuzzy")
        mpv_initialize(h)

        mpv_observe_property(h, 1, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(h, 2, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(h, 3, "demuxer-cache-time", MPV_FORMAT_DOUBLE)
        mpv_observe_property(h, 4, "container-fps", MPV_FORMAT_DOUBLE)
        mpv_observe_property(h, 5, "paused", MPV_FORMAT_FLAG)

        mpv_set_wakeup_callback(h, { ctx in
            guard let ctx else { return }
            let engine = Unmanaged<MPVEngine>.fromOpaque(ctx).takeUnretainedValue()
            engine.eventQueue.async { engine.drainEvents() }
        }, Unmanaged.passUnretained(self).toOpaque())

        startEventLoop()
        #endif
    }

    deinit {
        #if canImport(MPVKit)
        eventLoopRunning = false
        if let renderContext { mpv_render_context_free(renderContext) }
        if let handle { mpv_terminate_destroy(handle) }
        #endif
    }

    // MARK: - 加载

    func load(_ item: PlayableItem) async throws {
        #if canImport(MPVKit)
        guard let handle else { throw PlayerError.engineUnavailable }
        if !item.headers.isEmpty {
            let joined = item.headers.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            mpv_set_option_string(handle, "http-header-fields", joined)
        }
        var args = cArgs(["loadfile", item.url.absoluteString, "replace"])
        mpv_command(handle, args)
        freeArgs(args)
        if item.startPosition > 0 {
            var seek = cArgs(["seek", String(item.startPosition), "absolute"])
            mpv_command(handle, seek)
            freeArgs(seek)
        }
        #endif
    }

    // MARK: - 控制

    func play() { setFlag("paused", false) }
    func pause() { setFlag("paused", true) }
    var isPlaying: Bool {
        #if canImport(MPVKit)
        guard let handle else { return false }
        var flag: Int32 = 1
        mpv_get_property(handle, "paused", MPV_FORMAT_FLAG, &flag)
        return flag == 0
        #else
        return false
        #endif
    }

    func seek(to seconds: TimeInterval) {
        #if canImport(MPVKit)
        guard let handle else { return }
        var args = cArgs(["seek", String(seconds), "absolute"])
        mpv_command(handle, args)
        freeArgs(args)
        #endif
    }

    func setRate(_ rate: Double) {
        #if canImport(MPVKit)
        guard let handle else { return }
        var v = rate
        mpv_set_property(handle, "speed", MPV_FORMAT_DOUBLE, &v)
        #endif
    }

    // MARK: - 轨道

    func availableTracks() -> [TrackInfo] {
        #if canImport(MPVKit)
        guard let handle else { return [] }
        guard let cStr = mpv_get_property_string(handle, "track-list") else { return [] }
        let json = String(cString: cStr)
        mpv_free(cStr)
        guard let list = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] else { return [] }
        return list.compactMap { t in
            guard let id = t["id"] as? Int,
                  let type = t["type"] as? String,
                  type == "audio" || type == "sub"
            else { return nil }
            return TrackInfo(id: "\(type == "audio" ? "a" : "s")\(id)",
                             kind: type == "audio" ? .audio : .subtitle,
                             name: (t["title"] as? String) ?? "轨道 \(id)",
                             language: t["lang"] as? String,
                             isDefault: (t["default"] as? Bool) ?? false)
        }
        #else
        return []
        #endif
    }

    func selectAudio(_ id: String) { setString("aid", String(id.dropFirst())) }
    func selectSubtitle(_ id: String?) {
        guard let id else { setString("sid", "no"); return }
        setString("sid", String(id.dropFirst()))
    }

    func loadExternalSubtitle(_ url: URL) {
        #if canImport(MPVKit)
        guard let handle else { return }
        var args = cArgs(["sub-add", url.absoluteString, "auto", "外挂字幕"])
        mpv_command(handle, args)
        freeArgs(args)
        #endif
    }

    // MARK: - 渲染

    func makeRenderView() -> Any {
        MPVRenderView(engine: self)
    }

    #if canImport(MPVKit)
    /// 渲染上下文挂在 view 的 EAGLContext 上（view 首次 layout 时调用）
    fileprivate func attachRenderContext(to view: MPVRenderView) -> Bool {
        guard renderContext == nil, let handle else { return false }
        EAGLContext.setCurrent(view.glContext)
        var getProcAddress: mpv_opengl_get_proc_address = { _, name in
            guard let name else { return nil }
            return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) // RTLD_DEFAULT
        }
        var glInit = mpv_opengl_init_params(get_proc_address: getProcAddress, get_proc_address_ctx: nil)
        var fbo = mpv_opengl_fbo(fbo: 0, w: Int32(view.bounds.width), h: Int32(view.bounds.height), internal_format: 0x8058)
        var flipY: Int8 = 1
        var params: [mpv_render_param] = [
            mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: MPV_RENDER_API_TYPE_OPENGL)),
            mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: &glInit),
            mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: &fbo),
            mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: &flipY),
            mpv_render_param(),
        ]
        let status = mpv_render_context_create(&renderContext, handle, &params)
        return status >= 0
    }

    fileprivate func renderFrame(width: Int32, height: Int32) {
        guard let renderContext else { return }
        var fbo = mpv_opengl_fbo(fbo: 0, w: width, h: height, internal_format: 0x8058)
        var flipY: Int8 = 1
        var params: [mpv_render_param] = [
            mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: &fbo),
            mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: &flipY),
            mpv_render_param(),
        ]
        mpv_render_context_render(renderContext, &params)
    }

    /// 事件线程：把属性变化转成 tick 流
    private func drainEvents() {
        guard let handle else { return }
        while true {
            guard let event = mpv_wait_event(handle, 0) else { break }
            let id = event.pointee.event_id
            if id == MPV_EVENT_NONE || id == MPV_EVENT_QUEUE_OVERFLOW { break }
            if id == MPV_EVENT_PROPERTY_CHANGE, let prop = event.pointee.data?.assumingMemoryBound(to: mpv_event_property.self) {
                let name = String(cString: prop.pointee.name)
                switch name {
                case "time-pos": if prop.pointee.format == MPV_FORMAT_DOUBLE { cachedPosition = prop.pointee.data.load(as: Double.self) }
                case "duration": if prop.pointee.format == MPV_FORMAT_DOUBLE { cachedDuration = prop.pointee.data.load(as: Double.self) }
                case "demuxer-cache-time": if prop.pointee.format == MPV_FORMAT_DOUBLE { cachedBuffered = prop.pointee.data.load(as: Double.self) }
                case "container-fps": if prop.pointee.format == MPV_FORMAT_DOUBLE { cachedFPS = prop.pointee.data.load(as: Double.self) }
                default: break
                }
                tickContinuation?.yield(PlaybackTick(
                    position: cachedPosition, duration: cachedDuration,
                    buffered: cachedBuffered, fps: cachedFPS, bitrateBps: cachedBitrate
                ))
            }
        }
    }

    private func startEventLoop() {
        eventLoopRunning = true
    }

    private func setFlag(_ name: String, _ value: Bool) {
        guard let handle else { return }
        var v: Int32 = value ? 1 : 0
        mpv_set_property(handle, name, MPV_FORMAT_FLAG, &v)
    }

    private func setString(_ name: String, _ value: String) {
        guard let handle else { return }
        mpv_set_property_string(handle, name, value)
    }

    // MARK: C 数组工具

    private func cArgs(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        strings.map { UnsafeMutablePointer<CChar>(strdup($0)) } + [nil]
    }
    private func freeArgs(_ args: [UnsafeMutablePointer<CChar>?]) {
        for a in args where a != nil { free(a) }
    }
    #endif
}

enum PlayerError: Error { case engineUnavailable }

// MARK: - 渲染视图（GLKView + CADisplayLink 驱动）

final class MPVRenderView: GLKView {
    let glContext: EAGLContext
    private weak var engine: MPVEngine?
    private var displayLink: CADisplayLink?

    init(engine: MPVEngine) {
        self.engine = engine
        self.glContext = EAGLContext(api: .openGLES3)!
        super.init(frame: .zero, context: glContext)
        enableSetNeedsDisplay = false
        drawableColorFormat = .rgba8888
        backgroundColor = .black

        EAGLContext.setCurrent(glContext)
        _ = engine.attachRenderContext(to: self)

        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func tick() {
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let engine else { return }
        let scale = Int32(truncatingIfNeeded: contentScaleFactor)
        engine.renderFrame(width: Int32(bounds.width) * scale, height: Int32(bounds.height) * scale)
    }
}

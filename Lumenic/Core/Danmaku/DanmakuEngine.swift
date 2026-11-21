import Foundation
import SwiftUI
import MetalKit
import CoreText

// MARK: - 弹幕引擎（Metal 自绘 + 三层防遮挡 + 密度自适应，方案 §5）
//
// 数据面（本类，主线程写 / 渲染线程读，NSLock 保护）：
//  - 弹幕池 live[]：进入时间、泳道、文本纹理 key
//  - 时间基准 sync(position:) 由播放 tick 驱动，渲染帧按墙钟插值出平滑时间轴
// 三层防遮挡：
//  1. 字幕区剔除 —— 底部固定弹幕整体抬到字幕带之上（avoidSubtitle）
//  2. 控件浮现下沉 —— 控制条出现时弹幕池整体下移并降透明度（suppressed）
//  3. 密度自适应 —— 泳道数随显示区域缩放，密度系数限制并发弹幕量，挤不下直接丢弃

// 说明：本类不加 @MainActor —— 渲染线程每帧都要读取状态，
// 全部可变状态由 NSLock 保护；@Published 设置项只在 UI 主线程写入。
final class DanmakuEngine: ObservableObject {
    enum Status: Equatable {
        case idle, loading
        case ready(count: Int, source: String)
        case failed(String)
    }

    // MARK: 用户设置（面板直接绑定）
    @Published var isEnabled = true
    @Published var density: Double = 1.0          // 0.2 ~ 3，>1 提高并发上限
    @Published var fontSize: Double = 18
    @Published var opacity: Double = 0.9
    @Published var areaRatio: Double = 0.5        // 显示区域高度占比
    @Published var avoidSubtitle = true           // 字幕区避让
    @Published var offset: Double = 0             // 时间轴校正（秒）
    /// 屏蔽词列表：命中关键词的弹幕不入池；变更即时重滤并持久化
    @Published var blocklist: [String] = DanmakuEngine.loadBlocklist() {
        didSet {
            guard blocklist != oldValue else { return }
            UserDefaults.standard.set(blocklist, forKey: "luplay.danmaku.blocklist")
            refilter()
        }
    }
    @Published private(set) var status: Status = .idle

    // MARK: 内部状态（锁保护）
    struct Live {
        let comment: DanmakuComment
        let enter: Double          // 播放时间轴上的进入时刻
        let lane: Int
        let fixed: Bool
        let widthPts: CGFloat
    }

    private let lock = NSLock()
    private var allComments: [DanmakuComment] = []   // 未过滤原始池（屏蔽词变更时重滤）
    private var comments: [DanmakuComment] = []
    private var nextIndex = 0
    private var live: [Live] = []
    private var laneFreeAt: [Double] = []
    private var topFreeAt: [Double] = []
    private var bottomFreeAt: [Double] = []

    private var basePosition: Double = 0
    private var baseWallTime: Double = CFAbsoluteTimeGetCurrent()
    private var playing = false
    private var rate: Double = 1.0
    private var duration: Double = 0

    private var viewport: CGSize = .zero          // 点单位
    private var pixelScale: CGFloat = 3
    private var suppressed: Double = 0            // 0~1

    // MARK: Metal（引擎持有，Renderer 共享）
    let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    private var textureCache: [String: MTLTexture] = [:]

    var hasMetal: Bool { device != nil }

    // MARK: 弹幕装载

    /// 播放器进入时登记匹配上下文（供面板“重新匹配”复用）
    private var lastMatchTitle: String?
    private var lastMatchEpisodeLabel: String?

    func prepareMatch(title: String, episodeLabel: String) {
        lastMatchTitle = title
        lastMatchEpisodeLabel = episodeLabel
    }

    func rematch(client: DandanplayClient) async {
        guard let title = lastMatchTitle else { return }
        await autoMatch(title: title, episodeLabel: lastMatchEpisodeLabel ?? "", client: client)
    }

    func setFailed(_ reason: String) {
        status = .failed(reason)
    }

    func load(_ newComments: [DanmakuComment], source: String) {
        lock.lock()
        allComments = newComments.sorted { $0.time < $1.time }
        comments = Self.filtered(allComments, by: blocklist)
        nextIndex = 0
        live = []
        laneFreeAt = []
        basePosition = 0
        baseWallTime = CFAbsoluteTimeGetCurrent()
        lock.unlock()
        status = .ready(count: comments.count, source: source)
    }

    func clear() {
        lock.lock()
        allComments = []
        comments = []; nextIndex = 0; live = []
        lock.unlock()
        status = .idle
    }

    /// 屏蔽词持久化读取
    private static func loadBlocklist() -> [String] {
        UserDefaults.standard.stringArray(forKey: "luplay.danmaku.blocklist") ?? []
    }

    /// 关键词过滤（大小写不敏感的包含匹配）
    private static func filtered(_ list: [DanmakuComment], by blocklist: [String]) -> [DanmakuComment] {
        let words = blocklist.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return list }
        return list.filter { c in
            let t = c.text.lowercased()
            return !words.contains { t.contains($0) }
        }
    }

    /// 屏蔽词变更：重滤弹幕池；时间轴位置保持，已上屏弹幕清空待重排
    private func refilter() {
        lock.lock()
        comments = Self.filtered(allComments, by: blocklist)
        let pos = effectivePosition()
        nextIndex = comments.firstIndex { $0.time >= pos } ?? comments.count
        live = []
        laneFreeAt = []
        topFreeAt = []
        bottomFreeAt = []
        let count = comments.count
        let source: String
        if case .ready(_, let s) = status { source = s } else { source = "" }
        lock.unlock()
        if case .ready = status {
            status = .ready(count: count, source: source)
        }
    }

    /// 自动匹配：弹弹play → 失败兜底演示弹幕
    func autoMatch(title: String, episodeLabel: String, client: DandanplayClient) async {
        status = .loading
        let episodeNumber = EpisodeParser.guessNumber(from: episodeLabel) ?? 0
        do {
            guard let (anime, ep) = try await client.match(title: title, episodeNumber: episodeNumber) else {
                load(MockDanmaku.generate(duration: durationForMock), source: "演示弹幕（未匹配到作品）")
                status = .failed("未匹配到弹幕库，已载入演示弹幕")
                return
            }
            let list = try await client.comments(episodeId: ep.episodeId)
            if list.isEmpty {
                load(MockDanmaku.generate(duration: durationForMock), source: "演示弹幕")
                status = .failed("「\(anime.title) · \(ep.title)」弹幕为空，已载入演示弹幕")
            } else {
                load(list, source: "弹弹play · \(anime.title) · \(ep.title)")
            }
        } catch {
            load(MockDanmaku.generate(duration: durationForMock), source: "演示弹幕")
            status = .failed("匹配失败：\((error as? DandanplayClient.DanjakuError)?.description ?? "网络异常")，已载入演示弹幕")
        }
    }

    private var durationForMock: Double {
        lock.lock()
        let d = duration
        lock.unlock()
        return d > 30 ? d : 600
    }

    // MARK: 播放时间轴同步（容器在 tick / 播放态变化时调用）

    nonisolated func sync(position: Double) {
        lock.lock()
        basePosition = position
        baseWallTime = CFAbsoluteTimeGetCurrent()
        lock.unlock()
    }

    nonisolated func setPlaying(_ p: Bool, rate r: Double = 1.0) {
        lock.lock()
        // 恢复播放时以当前状态为基准续算，暂停时冻结
        if playing != p { baseWallTime = CFAbsoluteTimeGetCurrent() }
        playing = p
        rate = r
        lock.unlock()
    }

    nonisolated func setDuration(_ d: Double) { lock.lock(); duration = d; lock.unlock() }

    nonisolated func setSuppressed(_ s: Double) { lock.lock(); suppressed = s; lock.unlock() }

    nonisolated func setViewport(_ size: CGSize, scale: CGFloat) {
        lock.lock()
        if size != viewport {
            viewport = size
            pixelScale = scale
            laneFreeAt = []      // 视口变化重排泳道
        }
        lock.unlock()
    }

    private func effectivePosition() -> Double {
        let elapsed = playing ? max(0, CFAbsoluteTimeGetCurrent() - baseWallTime) * rate : 0
        return basePosition + elapsed + offset
    }

    // MARK: 泳道布局 + 密度自适应（渲染线程调用）

    private struct Frame {
        var items: [Live]
        var pos: Double
        var viewport: CGSize
        var scale: CGFloat
        var suppressed: Double
        var opacity: Double
        var fontSize: Double
        var areaRatio: Double
        var avoidSubtitle: Bool
        var subtitleBand: CGFloat
        var laneHeight: CGFloat
        var enabled: Bool
    }

    /// 每帧推进：吐出新进入的弹幕、清理过期、做三层防遮挡决策
    nonisolated func frame() -> Frame {
        lock.lock()
        defer { lock.unlock() }

        let pos = effectivePosition()
        let size = viewport
        let laneHeight = CGFloat(fontSize) * 1.4

        // 1. 密度自适应：泳道数 = 可用高度 × 显示区域 ÷ 行高；并发上限随密度系数缩放
        if laneFreeAt.isEmpty, size.height > 0 {
            let lanes = max(1, Int((size.height * CGFloat(areaRatio)) / laneHeight))
            laneFreeAt = Array(repeating: -1, count: lanes)
            topFreeAt = Array(repeating: -1, count: max(1, lanes / 2))
            bottomFreeAt = Array(repeating: -1, count: max(1, lanes / 2))
        }

        // 2. 吐弹：时间轴到达且泳道/并发有余量；挤不下按密度丢弃（不过载）
        let scrollLanes = max(1, Int(Double(laneFreeAt.count) * min(density, 1.0)))
        let maxLive = max(6, Int(36.0 * min(density, 2.5)))
        if isEnabled {
            while nextIndex < comments.count, comments[nextIndex].time <= pos {
                let c = comments[nextIndex]
                nextIndex += 1
                if live.count >= maxLive { continue }
                let w = estimatedWidth(c.text)
                let cross = 7.0
                switch c.mode {
                case .scroll:
                    if let lane = (0..<scrollLanes).first(where: { laneFreeAt[$0] <= c.time }) {
                        // 该泳道在前一条尾巴让出 ~30pt 间隙后复用
                        laneFreeAt[lane] = c.time + cross * Double(w + 30) / Double(size.width + w)
                        live.append(Live(comment: c, enter: c.time, lane: lane, fixed: false, widthPts: w))
                    }
                case .top:
                    if let slot = (0..<topFreeAt.count).first(where: { topFreeAt[$0] <= c.time }) {
                        topFreeAt[slot] = c.time + 4.5
                        live.append(Live(comment: c, enter: c.time, lane: slot, fixed: true, widthPts: w))
                    }
                case .bottom:
                    let band = avoidSubtitle ? size.height * 0.18 : 0
                    let slots = max(1, Int((size.height - band - CGFloat(fontSize) * 6) / laneHeight))
                    if let slot = (0..<min(bottomFreeAt.count, slots)).first(where: { bottomFreeAt[$0] <= c.time }) {
                        bottomFreeAt[slot] = c.time + 4.5
                        live.append(Live(comment: c, enter: c.time, lane: slot, fixed: true, widthPts: w))
                    }
                }
            }
        }

        // 3. 清理过期
        live.removeAll { l in
            switch l.comment.mode {
            case .scroll:
                let cross = 7.0
                return pos - l.enter > cross
            case .top, .bottom:
                return pos - l.enter > 5.0
            }
        }

        let subtitleBand = avoidSubtitle ? size.height * 0.18 : 0
        return Frame(items: live, pos: pos, viewport: size, scale: pixelScale,
                     suppressed: suppressed, opacity: opacity, fontSize: fontSize,
                     areaRatio: areaRatio, avoidSubtitle: avoidSubtitle,
                     subtitleBand: subtitleBand, laneHeight: laneHeight, enabled: isEnabled)
    }

    private func estimatedWidth(_ text: String) -> CGFloat {
        let pts = CGFloat(fontSize)
        var w: CGFloat = 0
        for scalar in text.unicodeScalars {
            w += scalar.value >= 0x2E80 ? pts : pts * 0.55   // CJK 全宽，其余半宽
        }
        return w + pts * 0.6
    }

    // MARK: 文本纹理（CoreText 离屏绘制，渲染线程安全）

    nonisolated func texture(for live: Live, device: MTLDevice) -> MTLTexture? {
        let key = "\(live.comment.text)|\(live.comment.color)|\(Int(fontSize))"
        lock.lock()
        if let hit = textureCache[key] { lock.unlock(); return hit }
        lock.unlock()

        guard let made = makeTexture(text: live.comment.text, color: live.comment.color) else { return nil }
        do {
            let tex = try MTKTextureLoader(device: device).newTexture(cgImage: made.image, options: [:])
            lock.lock()
            if textureCache.count > 400 { textureCache.removeAll(keepingCapacity: true) }  // 防膨胀
            textureCache[key] = tex
            lock.unlock()
            return tex
        } catch {
            return nil
        }
    }

    nonisolated func invalidateTextures() {
        lock.lock()
        textureCache.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// CoreText 渲染：黑边描摹 + 主文本，2x 缩放保证清晰度
    private nonisolated func makeTexture(text: String, color: UInt32) -> (image: CGImage, size: CGSize)? {
        let fontSize = CGFloat(fontSize) * 2   // 2x
        let ctFont = CTFontCreateWithName("PingFangSC-Semibold" as CFString, fontSize, nil)
        let cgColor = Self.color(from: color)
        let attr = NSAttributedString(string: text, attributes: [
            .font: ctFont,
            .foregroundColor: UIColor(cgColor: cgColor),
        ])
        let line = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let w = CGFloat(ceil(CTLineGetTypographicBounds(line, &ascent, &descent, &leading)))
        let stroke: CGFloat = 4   // 2x 下的描边宽度 ≈ 屏上 2pt
        let size = CGSize(width: w + stroke * 2, height: ceil(ascent + descent) + stroke * 2)
        guard size.width > 1, size.height > 1 else { return nil }

        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: Int(size.width) * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        // 描边：四向偏移画黑色底
        ctx.setTextPosition(stroke, stroke)
        for (dx, dy) in [(stroke, 0), (-stroke, 0), (0, stroke), (0, -stroke)] as [(CGFloat, CGFloat)] {
            ctx.setTextPosition(stroke + dx, stroke + dy)
            ctx.setShadow(offset: .zero, blur: 2, color: UIColor.black.cgColor)
            CTLineDraw(line, ctx)
        }
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setTextPosition(stroke, stroke)
        CTLineDraw(line, ctx)

        return (ctx.makeImage()!, size)
    }

    private static func color(from hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Metal 渲染器（每帧取引擎快照绘制文本纹理四边形）

final class DanmakuRenderer: NSObject, MTKViewDelegate {
    private let engine: DanmakuEngine
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let vertexBuffer: MTLBuffer
    private static let maxQuads = 220
    /// 每顶点：pos(2) + uv(2) + alpha(1)，stride 20 字节
    private static let stride = 5

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VIn {
        float2 pos   [[attribute(0)]];
        float2 uv    [[attribute(1)]];
        float alpha  [[attribute(2)]];
    };
    struct VOut {
        float4 position [[position]];
        float2 uv;
        float alpha;
    };
    vertex VOut dm_vertex(constant VIn *in [[buffer(0)]],
                          constant float2 &viewportPx [[buffer(1)]],
                          uint vid [[vertex_id]]) {
        VOut o;
        float2 p = in[vid].pos;
        o.position = float4(p.x / viewportPx.x * 2.0 - 1.0, 1.0 - p.y / viewportPx.y * 2.0, 0.0, 1.0);
        o.uv = in[vid].uv;
        o.alpha = in[vid].alpha;
        return o;
    }
    fragment float4 dm_fragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(address::clamp_to_edge);
        float4 c = tex.sample(s, in.uv);
        return float4(c.rgb * in.alpha, c.a * in.alpha);   // 预乘输出
    }
    """

    init?(engine: DanmakuEngine) {
        guard let device = engine.device, let queue = device.makeCommandQueue() else { return nil }
        self.engine = engine
        self.queue = queue
        do {
            let lib = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "dm_vertex")
            desc.fragmentFunction = lib.makeFunction(name: "dm_fragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].rgbBlendOperation = .add
            desc.colorAttachments[0].sourceRGBBlendFactor = .one                 // 预乘输入
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            let vd = MTLVertexDescriptor()
            vd.attributes[0].format = .float2; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 0
            vd.attributes[1].format = .float2; vd.attributes[1].offset = 8; vd.attributes[1].bufferIndex = 0
            vd.attributes[2].format = .float1; vd.attributes[2].offset = 16; vd.attributes[2].bufferIndex = 0
            vd.layouts[0].stride = Self.stride * 4
            desc.vertexDescriptor = vd
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            return nil
        }
        vertexBuffer = device.makeBuffer(length: Self.maxQuads * 4 * Self.stride * 4,
                                         options: .storageModeShared)!
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer() else { return }

        let frame = engine.frame()
        let px = view.drawableSize
        guard frame.enabled, px.width > 1 else {
            cmd.present(drawable); cmd.commit()
            return
        }

        var groups: [(tex: MTLTexture, verts: [Float])] = []
        let suppressShift = Float(frame.suppressed * 90)   // 控件浮现：弹幕池整体下沉

        for item in frame.items {
            guard let tex = engine.texture(for: item, device: view.device!) else { continue }
            let tw = Float(tex.width), th = Float(tex.height)
            let scale = Float(frame.scale)
            let texW = tw / scale, texH = th / scale   // 像素 → 点

            let elapsed = frame.pos - item.enter
            var x: Float, y: Float, alpha: Float
            switch item.comment.mode {
            case .scroll:
                let progress = elapsed / 7.0
                x = Float(frame.viewport.width) - progress * (Float(frame.viewport.width) + texW)
                y = Float(item.lane) * Float(frame.laneHeight) + 6 + suppressShift
                alpha = Float(frame.opacity)
            case .top:
                x = (Float(frame.viewport.width) - texW) / 2
                y = 8 + Float(item.lane) * Float(frame.laneHeight) + suppressShift
                alpha = Float(frame.opacity) * min(1, max(0, Float(5.0 - elapsed) / 0.5))
            case .bottom:
                x = (Float(frame.viewport.width) - texW) / 2
                y = Float(frame.viewport.height) - Float(frame.subtitleBand)
                    - Float(item.lane + 1) * Float(frame.laneHeight) - 4 + suppressShift
                alpha = Float(frame.opacity) * min(1, max(0, Float(5.0 - elapsed) / 0.5))
            }
            alpha *= Float(1 - frame.suppressed * 0.55)        // 控件浮现：透明度让位
            guard alpha > 0.01 else { continue }

            // 汇入该纹理的顶点组（像素坐标，y 向下）
            let l = x * scale, r = (x + texW) * scale, t = y * scale, b = (y + texH) * scale
            if groups.last?.tex !== tex || groups.isEmpty {
                groups.append((tex, []))
            }
            groups[groups.count - 1].verts.append(contentsOf: [l, t, 0, 0, alpha])   // 左上
            groups[groups.count - 1].verts.append(contentsOf: [r, t, 1, 0, alpha])   // 右上
            groups[groups.count - 1].verts.append(contentsOf: [l, b, 0, 1, alpha])   // 左下
            groups[groups.count - 1].verts.append(contentsOf: [r, b, 1, 1, alpha])   // 右下
        }

        if let encoder = cmd.makeRenderCommandEncoder(descriptor: pass) {
            encoder.setRenderPipelineState(pipeline)
            var vp = SIMD2<Float>(Float(px.width), Float(px.height))
            encoder.setVertexBytes(&vp, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            var totalQuads = 0
            for group in groups {
                let quadCount = group.verts.count / (Self.stride * 4)
                guard quadCount > 0,
                      totalQuads + quadCount <= Self.maxQuads,
                      group.verts.count * MemoryLayout<Float>.size <= vertexBuffer.length else { continue }
                memcpy(vertexBuffer.contents(), group.verts, group.verts.count * MemoryLayout<Float>.size)
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                encoder.setFragmentTexture(group.tex, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: group.verts.count / Self.stride)
                totalQuads += quadCount
            }
            encoder.endEncoding()
        }
        cmd.present(drawable)
        cmd.commit()
    }
}

// MARK: - SwiftUI 桥接（MTKView）

struct DanmakuOverlay: UIViewRepresentable {
    let engine: DanmakuEngine

    func makeUIView(context: Context) -> UIView {
        guard engine.hasMetal, let renderer = DanmakuRenderer(engine: engine) else {
            return UIView()   // 无 Metal 环境静默降级
        }
        let view = MTKView(frame: .zero, device: engine.device)
        view.delegate = renderer
        view.isOpaque = false
        view.backgroundColor = .clear
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 60
        view.framebufferOnly = true
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        context.coordinator.renderer = renderer
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let view = uiView as? MTKView else { return }
        engine.setViewport(view.bounds.size, scale: view.contentScaleFactor)
    }

    func makeCoordinator(context: Context) -> Coordinator { Coordinator() }

    final class Coordinator {
        var renderer: DanmakuRenderer?
    }
}

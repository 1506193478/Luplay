import SwiftUI
import AVKit

/// 播放器容器：全屏视频层 + 顶部信息条 + 底部控制条 + 右侧工具簇 + 玻璃面板。
/// 视频输出与控制走 PlaybackSession；片源来自 PlayRequest（真实片源 / 演示流）。
struct PlayerContainerView: View {
    let request: PlayRequest
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var env: AppEnvironment

    @StateObject private var session: PlaybackSession
    @StateObject private var danmakuEngine = DanmakuEngine()
    @State private var controlsVisible = true
    @State private var activePanel: Panel?
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var selectedOptionID: String
    @State private var skipMarker: SkipMarker?
    @State private var autoSkipFired = false

    init(request: PlayRequest) {
        self.request = request
        // 内核自动选择（方案 §3.4）：按最佳片源信息实时推荐（设置页"默认内核"可覆盖）；mpv 不可用时回退
        let best = request.bestOption
        var kind = best.map { EngineSelector.recommend(container: $0.info.container,
                                                       codec: $0.info.codec, hdr: $0.info.hdr) } ?? .avplayer
        if kind == .mpv && !MPVEngine.isAvailable { kind = .avplayer }
        let mediaKey = "\(request.title)|\(request.episodeLabel)"
        _session = StateObject(wrappedValue: PlaybackSession(
            kind: kind,
            mediaKey: mediaKey,
            database: AppDatabase.inMemory
        ))
        _selectedOptionID = State(initialValue: best?.id ?? "")
    }

    private var currentOption: StreamOption? {
        request.options.first { $0.id == selectedOptionID } ?? request.bestOption
    }

    enum Panel: String { case sources = "来源", danmaku = "弹幕", subtitle = "字幕", cast = "投屏", more = "更多", debug = "调试" }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            videoLayer
                .ignoresSafeArea()

            // 弹幕层（Metal 自绘，位于视频之上、控件之下）
            DanmakuOverlay(engine: danmakuEngine)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack { topBar; Spacer(); skipPill; controlBar }
            toolCluster
            panelLayer
        }
        .onTapGesture { withAnimation(.dsSpring) { controlsVisible.toggle() } }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        // 横屏闸门：仅播放页放行横屏（物理朝向跟随）；关闭播放器自动旋回竖屏
        .onAppear { OrientationGate.shared.allowLandscape = true }
        .task {
            // 重绑真实数据库（init 时 env 不可用只能用内存库）
            session.useDatabase(env.database)
            guard var opt = currentOption else { return }
            // 直链时效（Alist raw_url 有时效）：起播前重取最新直链
            if let refresh = opt.refresh, let fresh = try? await refresh() { opt.info = fresh }
            await session.start(PlayableItem(url: opt.info.url, headers: opt.info.headers,
                                             engine: session.engineKind, startPosition: 0))
            // 片头片尾标记（M6）
            skipMarker = try? env.database.skipMarker(forKey: session.storageKey)
            // 弹幕自动匹配（弹弹play；失败自动落演示弹幕）
            danmakuEngine.prepareMatch(title: request.title, episodeLabel: request.episodeLabel)
            await danmakuEngine.autoMatch(title: request.title,
                                          episodeLabel: request.episodeLabel,
                                          client: env.dandanplay)
        }
        .onChange(of: session.tick?.position) { _, pos in
            guard let pos else { return }
            danmakuEngine.sync(position: pos)
            autoSkipIfNeeded(at: pos)
        }
        .onChange(of: session.tick?.duration) { _, dur in
            guard let dur else { return }
            danmakuEngine.setDuration(dur)
        }
        .onChange(of: session.isPlaying) { _, playing in
            danmakuEngine.setPlaying(playing, rate: session.rate)
        }
        .onChange(of: session.rate) { _, rate in
            danmakuEngine.setPlaying(session.isPlaying, rate: rate)
        }
        // 三层防遮挡之二：控件浮现 → 弹幕池下沉 + 让透明度
        .onChange(of: controlsVisible) { _, visible in
            danmakuEngine.setSuppressed(visible ? 1 : 0)
        }
        .onDisappear {
            OrientationGate.shared.allowLandscape = false   // 关闸 → 系统旋回竖屏
            session.close()
        }
    }

    // MARK: 视频层
    private var videoLayer: some View {
        EngineSurface(engine: session.engine)
    }

    // MARK: 顶部信息条
    private var topBar: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.dsInk)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(request.title).font(.system(size: 16, weight: .bold)).foregroundStyle(.dsInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(request.episodeLabel).font(.dsCaption).foregroundStyle(.dsInk2)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let info = currentOption?.info {
                        Text(info.hdr).badgeStyle(highlight: info.hdr != "SDR")
                        Text("\(info.resolution) · \(info.container.uppercased())")
                            .font(.dsCaption).foregroundStyle(.dsInk2)
                        if info.bitrateMbps > 0 {
                            Text(String(format: "%.1fMbps", info.bitrateMbps))
                                .font(.dsCaption).foregroundStyle(.dsInk2)
                        }
                    } else {
                        Text("无片源").font(.dsCaption).foregroundStyle(.dsInk2)
                    }
                }
            }
            Spacer()
            // 缓冲健康度（对标调试条）
            Text(bufferText)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.dsInk2)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .opacity(controlsVisible ? 1 : 0)
        .animation(.dsSpring, value: controlsVisible)
    }

    private var bufferText: String {
        guard let t = session.tick else { return "加载中…" }
        let buf = max(0, t.buffered - t.position)
        return String(format: "BUF %.1fs", buf)
    }

    // MARK: 底部控制条（两行布局：窄屏不再挤压裁切）
    private var controlBar: some View {
        VStack(spacing: 10) {
            slider
            HStack(spacing: 18) {
                Button {
                    session.isPlaying ? session.pause() : session.play()
                } label: {
                    Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .bold))
                }
                Button { session.seek(to: max(0, (session.tick?.position ?? 0) - 10)) } label: {
                    Image(systemName: "gobackward.10").font(.system(size: 17))
                }
                Spacer()
                speedPill
                enginePill
            }
            .foregroundStyle(.dsInk)
            .padding(.horizontal, 18)

            // 面板行：均匀分布，图标不再互相挤压
            HStack(spacing: 0) {
                panelButton(.cast, icon: "rectangle.on.rectangle")
                pipButton
                panelButton(.sources, icon: "square.stack.3d.up")
                panelButton(.subtitle, icon: "captions.bubble")
                panelButton(.danmaku, icon: "text.bubble")
                panelButton(.more, icon: "ellipsis.circle")
            }
            .foregroundStyle(.dsInk)
            .padding(.horizontal, 18)
            .padding(.bottom, 26)
        }
        .opacity(controlsVisible ? 1 : 0)
        .animation(.dsSpring, value: controlsVisible)
    }

    private var pipButton: some View {
        Button { session.togglePiP() } label: {
            Image(systemName: "rectangle.inset.filled.on.rectangle.filled")
                .font(.system(size: 17))
        }
        .disabled(!(session.engine.capabilities.contains(.pip)))
        .opacity(session.engine.capabilities.contains(.pip) ? 1 : 0.35)
        .frame(maxWidth: .infinity)
    }

    private var slider: some View {
        let duration = session.tick?.duration ?? 0
        let position = scrubbing ? scrubValue : (session.tick?.position ?? 0)
        let fraction = duration > 0 ? min(1, position / duration) : 0
        return HStack(spacing: 10) {
            Text(timeString(position)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.dsInk)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22)).frame(height: 3)
                    Capsule().fill(.white).frame(width: geo.size.width * fraction, height: 3)
                    Circle().fill(.white).frame(width: 12, height: 12)
                        .offset(x: geo.size.width * fraction - 6)
                }
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    scrubbing = true
                    controlsVisible = true
                    scrubValue = min(max(0, v.location.x / geo.size.width), 1) * duration
                }.onEnded { _ in
                    session.seek(to: scrubValue)
                    scrubbing = false
                })
            }
            .frame(height: 12)
            Text(timeString(duration)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.dsInk)
        }
        .padding(.horizontal, 18)
    }

    private var speedPill: some View {
        Button {
            let next = session.rate == 1.0 ? 1.5 : (session.rate == 1.5 ? 2.0 : 1.0)
            session.setRate(next)
        } label: {
            Text("\(String(format: "%g", session.rate))×")
                .font(.system(size: 12, weight: .bold))
                .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .background(Capsule().fill(Color.dsGlassBorder))
        .foregroundStyle(.dsInk)
    }

    /// 内核切换（保留进度实时切换，方案 §4.3）
    private var enginePill: some View {
        Button {
            let next: EngineKind = session.engineKind == .avplayer ? .mpv : .avplayer
            if next == .mpv && !MPVEngine.isAvailable { return }
            Task { await session.switchEngine(to: next) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "cpu")
                Text(session.engineKind == .avplayer ? "AVPlayer" : "mpv")
                    .font(.system(size: 12, weight: .bold))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .background(Capsule().fill(Color.dsGlassBorder))
        .foregroundStyle(.dsInk)
    }

    private func panelButton(_ p: Panel, icon: String) -> some View {
        Button { withAnimation(.dsEaseOut) { activePanel = p } } label: {
            Image(systemName: icon).font(.system(size: 17))
        }
        .frame(maxWidth: .infinity)   // 面板行均匀分布，图标永不裁切
    }

    // MARK: 右侧工具簇（真实功能；锚定在控制条上方，不再用硬偏移）
    private var toolCluster: some View {
        VStack(spacing: 14) {
            toolIcon("text.bubble") {
                withAnimation(.dsEaseOut) { activePanel = .danmaku }
            }
            toolIcon("rectangle.inset.filled.on.rectangle.filled",
                     enabled: session.engine.capabilities.contains(.pip)) {
                session.togglePiP()
            }
            toolIcon("ellipsis") {
                withAnimation(.dsEaseOut) { activePanel = .more }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 18)
        .padding(.bottom, 150)   // 悬在控制条上方，随控件条一起显隐
        .opacity(controlsVisible ? 1 : 0)
        .animation(.dsSpring, value: controlsVisible)
    }

    private func toolIcon(_ name: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            GlassSurface(shape: .capsule, interactive: true) {
                Image(systemName: name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.dsInk)
                    .frame(width: 42, height: 42)
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    // MARK: 玻璃面板层
    @ViewBuilder
    private var panelLayer: some View {
        if let panel = activePanel {
            switch panel {
            case .sources:
                SourceComparePanel(options: request.options,
                                   selectedID: $selectedOptionID,
                                   onSelect: { option in
                                       Task { await switchTo(option) }
                                   },
                                   onClose: { withAnimation(.dsEaseOut) { activePanel = nil } })
            case .danmaku:
                DanmakuPanel(engine: danmakuEngine, client: env.dandanplay,
                             onClose: { withAnimation(.dsEaseOut) { activePanel = nil } })
            case .cast:
                CastPanel(session: session,
                          streamInfo: currentOption?.info,
                          title: "\(request.title) \(request.episodeLabel)",
                          onClose: { withAnimation(.dsEaseOut) { activePanel = nil } })
            case .more:
                MorePanel(session: session,
                          database: env.database,
                          onOpenDebug: { withAnimation(.dsEaseOut) { activePanel = .debug } },
                          onClose: {
                              // 标记可能刚在面板里改过，关闭时同步回来
                              skipMarker = try? env.database.skipMarker(forKey: session.storageKey)
                              withAnimation(.dsEaseOut) { activePanel = nil }
                          })
            case .debug:
                DebugPanel(session: session,
                           option: currentOption,
                           onClose: { withAnimation(.dsEaseOut) { activePanel = nil } })
            case .subtitle:
                SubtitlePanel(session: session,
                              onClose: { withAnimation(.dsEaseOut) { activePanel = nil } })
            }
        }
    }

    /// 换源（进度保留，M4 来源对比；直链有时效的片源先刷新再切换）
    private func switchTo(_ option: StreamOption) async {
        guard option.id != selectedOptionID else { return }
        var info = option.info
        if let refresh = option.refresh, let fresh = try? await refresh() { info = fresh }
        await session.switchSource(to: PlayableItem(url: info.url, headers: info.headers,
                                                    engine: session.engineKind, startPosition: 0))
    }

    // MARK: 片头片尾跳过（M6）

    /// 是否处于片头区间（供"跳过片头"浮标）
    private var inIntroRange: Bool {
        guard let m = skipMarker, let start = m.introStart, let end = m.introEnd,
              let pos = session.tick?.position
        else { return false }
        return pos >= start && pos < end - 0.5
    }

    @ViewBuilder
    private var skipPill: some View {
        if inIntroRange {
            HStack {
                Spacer()
                Button { skipIntro() } label: {
                    HStack(spacing: 6) {
                        Text("跳过片头")
                            .font(.system(size: 13, weight: .bold))
                        Image(systemName: "forward.end.fill").font(.system(size: 11, weight: .bold))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9)
                }
                .background(Capsule().fill(Color.dsGlassFill))
                .overlay(Capsule().strokeBorder(Color.dsGlassBorder))
                .foregroundStyle(.dsInk)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    /// 自动跳过：进入片头区间即跳到片头结束点（每次进入区间只触发一次）
    private func autoSkipIfNeeded(at pos: Double) {
        guard let m = skipMarker, let start = m.introStart, let end = m.introEnd else { return }
        let inRange = pos >= start && pos < end - 0.5
        if !inRange { autoSkipFired = false }
        guard inRange, m.autoSkip, !autoSkipFired else { return }
        autoSkipFired = true
        skipIntro()
    }

    private func skipIntro() {
        guard let m = skipMarker, let end = m.introEnd else { return }
        session.seek(to: end)
        if !session.isPlaying { session.play() }
    }

    private func timeString(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t), h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

extension View {
    @ViewBuilder
    func badgeStyle(highlight: Bool) -> some View {
        font(.system(size: 10, weight: .heavy))
            .foregroundStyle(highlight ? .yellow : .dsInk)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(highlight ? Color.yellow.opacity(0.18) : Color.dsGlassBorder))
    }
}

// MARK: - 引擎渲染层桥接

struct EngineSurface: UIViewRepresentable {
    let engine: PlayerEngine

    func makeUIView(context: Context) -> UIView {
        engine.makeRenderView() as? UIView ?? UIView()
    }
    func updateUIView(_ view: UIView, context: Context) {}
}

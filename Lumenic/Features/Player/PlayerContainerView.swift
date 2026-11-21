import SwiftUI
import AVKit
import MediaPlayer

/// 播放器容器：全屏视频层 + 顶部信息条 + 底部控制条 + 右侧工具簇 + 玻璃面板。
/// 视频输出与控制走 PlaybackSession；片源来自 PlayRequest（真实片源 / 演示流）。
/// 支持浮窗模式（mini）：视频层缩为可拖动小窗，页面内容与 Tab 栏透传可用。
/// 全屏/浮窗共用同一 EngineSurface 视图身份（mpv GL 渲染上下文不重建）。
struct PlayerContainerView: View {
    let request: PlayRequest
    @Binding var mini: Bool
    let onClose: () -> Void
    @EnvironmentObject private var env: AppEnvironment

    /// 当前生效的播放请求（切集时整体重建，进度按集落盘）
    @State private var activeRequest: PlayRequest
    @State private var switchingEpisode = false
    @State private var switchingSource = false

    /// 浮窗尺寸（16:9）
    static let miniWindowSize = CGSize(width: 168, height: 94)

    @StateObject private var session: PlaybackSession
    @StateObject private var danmakuEngine = DanmakuEngine()
    @State private var controlsVisible = true
    @State private var activePanel: Panel?
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var selectedOptionID: String
    @State private var skipMarker: SkipMarker?
    @State private var autoSkipFired = false
    @State private var miniDrag: CGSize = .zero   // 相对默认停靠点（右下）的拖动偏移
    @State private var bounds: CGSize = .zero     // 容器安全区内尺寸（浮窗定位/钳制用）

    // MARK: 手势状态（全屏）
    @State private var locked = false             // 锁屏防误触
    @State private var hud: GestureHud?           // 手势 HUD 反馈
    @State private var hudTask: Task<Void, Never>?
    @State private var singleTapTask: Task<Void, Never>?
    @State private var boostRate: Double?         // 长按 2x 速览前的原倍速
    @State private var panAxisSettled = false     // 滑动方向已判定
    @State private var panIsVertical = false
    @State private var panLeftSide = false
    @State private var panStartBrightness: Double = 0
    @State private var panStartVolume: Float = 0

    /// 手势 HUD 类型
    private enum GestureHud: Equatable {
        case seekBack, seekForward, playPause, boost
        case brightness(Double)   // 0-1
        case volume(Float)        // 0-1
    }

    init(request: PlayRequest, mini: Binding<Bool>, onClose: @escaping () -> Void) {
        self.request = request
        self._mini = mini
        self.onClose = onClose
        self._activeRequest = State(initialValue: request)
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
        activeRequest.options.first { $0.id == selectedOptionID } ?? activeRequest.bestOption
    }

    enum Panel: String { case sources = "来源", danmaku = "弹幕", subtitle = "字幕", cast = "投屏", more = "更多", speed = "倍速", debug = "调试", episodes = "剧集" }

    var body: some View {
        ZStack {
            // 背景：全屏模式黑底；浮窗模式透明且不拦截点击（透传页面与 Tab 栏）
            Color.black
                .ignoresSafeArea()
                .opacity(mini ? 0 : 1)
                .allowsHitTesting(!mini)

            videoLayer

            // 弹幕层（Metal 自绘，位于视频之上、控件之下）；浮窗模式隐藏
            DanmakuOverlay(engine: danmakuEngine)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .opacity(mini ? 0 : 1)

            // 手势层（仅全屏）：位于控件之下，按钮/进度条等子视图优先响应
            if !mini {
                gestureLayer
            }

            if mini {
                MiniPlayerChrome(session: session,
                                 size: Self.miniWindowSize,
                                 drag: $miniDrag,
                                 onExpand: { withAnimation(.dsSpring) { mini = false } },
                                 onClose: onClose)
                    .offset(miniOffset)
            } else {
                VStack { topBar; Spacer(); skipPill; controlBar }
                lockOverlay
                toolCluster
                panelLayer
                gestureHud
                if switchingEpisode {
                    // 切集遮罩：取流+重载期间挡住交互
                    ZStack {
                        Color.black.opacity(0.65).ignoresSafeArea()
                        VStack(spacing: 10) {
                            ProgressView().tint(.white)
                            Text("正在切换剧集…").font(.dsCaption).foregroundStyle(.dsInk)
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
        .background(
            // 容器尺寸回传（浮窗定位与边界钳制）
            GeometryReader { g in
                Color.clear.preference(key: ContainerSizeKey.self, value: g.size)
            }
        )
        .statusBarHidden(!mini)
        .persistentSystemOverlays(.hidden)
        .onPreferenceChange(ContainerSizeKey.self) { bounds = $0 }
        // 横屏闸门：仅全屏播放放行横屏（物理朝向跟随）；浮窗/关闭自动旋回竖屏
        .onAppear {
            OrientationGate.shared.allowLandscape = true
            SystemVolumeController.shared.attachIfNeeded()   // 提前挂载，音量滑杆就绪
        }
        .onChange(of: mini) { _, m in
            OrientationGate.shared.allowLandscape = !m
            if !m { controlsVisible = true }
        }
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
            danmakuEngine.prepareMatch(title: activeRequest.title, episodeLabel: activeRequest.episodeLabel)
            await danmakuEngine.autoMatch(title: activeRequest.title,
                                          episodeLabel: activeRequest.episodeLabel,
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
            hudTask?.cancel()
            singleTapTask?.cancel()
            endBoost()
            OrientationGate.shared.allowLandscape = false   // 关闸 → 系统旋回竖屏
            session.close()
        }
    }

    // MARK: 视频层（全屏/浮窗同一视图身份，仅几何变化）
    private var videoLayer: some View {
        EngineSurface(engine: session.engine)
            .id(session.engineKind)   // 换内核时重建渲染视图（新引擎需重新挂载渲染层）
            .frame(width: mini ? Self.miniWindowSize.width : nil,
                   height: mini ? Self.miniWindowSize.height : nil)
            .frame(maxWidth: mini ? nil : .infinity,
                   maxHeight: mini ? nil : .infinity)
            .clipShape(RoundedRectangle(cornerRadius: mini ? 12 : 0, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: mini ? 12 : 0, style: .continuous)
                    .strokeBorder(Color.white.opacity(mini ? 0.22 : 0))
            )
            .ignoresSafeArea(edges: mini ? Edge.Set() : .all)
            .offset(mini ? miniOffset : .zero)
    }

    /// 浮窗中心点相对容器中心的偏移：默认停靠右下（避开 Tab 栏），拖动后钳制在容器内
    private var miniOffset: CGSize {
        let win = Self.miniWindowSize
        guard bounds.width > win.width + 12, bounds.height > win.height + 12 else { return .zero }
        let margin: CGFloat = 12
        let bottomReserve: CGFloat = 86   // Tab 栏高度(62) + 底距(18) + 呼吸(6)
        let defaultCX = bounds.width - margin - win.width / 2
        let defaultCY = bounds.height - bottomReserve - win.height / 2
        let cx = min(max(defaultCX + miniDrag.width, win.width / 2 + 6), bounds.width - win.width / 2 - 6)
        let cy = min(max(defaultCY + miniDrag.height, win.height / 2 + 6), bounds.height - bottomReserve - win.height / 2)
        return CGSize(width: cx - bounds.width / 2, height: cy - bounds.height / 2)
    }

    // MARK: 顶部信息条
    private var topBar: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.dsInk)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(activeRequest.title).font(.system(size: 16, weight: .bold)).foregroundStyle(.dsInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(activeRequest.episodeLabel).font(.dsCaption).foregroundStyle(.dsInk2)
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
            // 剧集导航：上一集 / 下一集（仅剧集内容显示）
            if activeRequest.episodeTitles != nil {
                HStack(spacing: 8) {
                    epNavButton("chevron.left.2",
                                enabled: activeRequest.currentEpisodeIndex > 0) {
                        Task { await switchEpisode(to: activeRequest.currentEpisodeIndex - 1) }
                    }
                    epNavButton("chevron.right.2",
                                enabled: activeRequest.currentEpisodeIndex < (activeRequest.episodeTitles?.count ?? 0) - 1) {
                        Task { await switchEpisode(to: activeRequest.currentEpisodeIndex + 1) }
                    }
                }
            }
            // 缓冲健康度（对标调试条）
            Text(bufferText)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.dsInk2)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .opacity(controlsVisible ? 1 : 0)
        .offset(y: controlsVisible ? 0 : -18)
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
                if activeRequest.episodeTitles != nil {
                    panelButton(.episodes, icon: "list.bullet")
                }
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
        .offset(y: controlsVisible ? 0 : 28)
        .animation(.dsSpring, value: controlsVisible)
    }

    /// PiP 按钮：AVPlayer 走系统画中画；mpv 无系统 PiP → 收起为应用内浮窗
    private var pipButton: some View {
        Button {
            if session.engine.capabilities.contains(.pip) {
                session.togglePiP()
            } else {
                enterMini()
            }
        } label: {
            Image(systemName: "rectangle.inset.filled.on.rectangle.filled")
                .font(.system(size: 17))
        }
        .frame(maxWidth: .infinity)
    }

    /// 收起为浮窗（mpv 小窗）
    private func enterMini() {
        controlsVisible = true
        locked = false   // 浮窗模式无锁屏态，展开后控件直接可用
        withAnimation(.dsSpring) { mini = true }
    }

    // MARK: 手势层（仅全屏；锁屏/面板打开时不响应）

    private var gestureLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(overlayGestures)
            .animation(.dsSpring, value: hud)
    }

    /// 组合手势：双击分区（快退/快进/播放暂停）+ 单击显隐 + 竖滑亮度音量 + 长按 2x 速览
    private var overlayGestures: some Gesture {
        // 双击与单击同时监听：双击命中时撤销单击的延时任务
        let taps = SpatialTapGesture(count: 2)
            .onEnded { v in handleDoubleTap(at: v.location) }
            .simultaneously(with: TapGesture().onEnded { scheduleSingleTap() })
        // 竖滑：左半屏亮度、右半屏音量
        let pan = DragGesture(minimumDistance: 28)
            .onChanged { v in handlePan(v) }
            .onEnded { _ in handlePanEnd() }
        // 长按 0.5s 进入 2x 速览，松手恢复
        let boost = LongPressGesture(minimumDuration: 0.5)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { v in if case .second(true, _) = v { startBoost() } }
            .onEnded { _ in endBoost() }
        return taps.simultaneously(with: pan).simultaneously(with: boost)
    }

    private func handleDoubleTap(at location: CGPoint) {
        guard !locked, activePanel == nil, !scrubbing else { return }
        singleTapTask?.cancel()
        singleTapTask = nil
        let width = max(1, bounds.width)
        let x = location.x / width
        if x < 0.35 {
            seekRel(-10)
            hud = .seekBack
        } else if x > 0.65 {
            seekRel(10)
            hud = .seekForward
        } else {
            session.isPlaying ? session.pause() : session.play()
            hud = .playPause
        }
        scheduleHudHide()
    }

    /// 单击显隐控件（延时执行，双击时会被撤销）
    private func scheduleSingleTap() {
        guard !locked, activePanel == nil else { return }
        singleTapTask?.cancel()
        singleTapTask = Task {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            withAnimation(.dsSpring) { controlsVisible.toggle() }
        }
    }

    private func handlePan(_ v: DragGesture.Value) {
        guard !locked, activePanel == nil, !scrubbing else { return }
        if !panAxisSettled {
            guard abs(v.translation.height) > 22 else { return }
            panAxisSettled = true
            panIsVertical = abs(v.translation.height) > abs(v.translation.width) * 1.2
            panLeftSide = v.startLocation.x < bounds.width / 2
            if panIsVertical {
                if panLeftSide { panStartBrightness = UIScreen.main.brightness }
                else { panStartVolume = SystemVolumeController.shared.current }
            }
        }
        guard panIsVertical else { return }
        let delta = -v.translation.height / 300.0
        if panLeftSide {
            let nb = min(1, max(0.02, panStartBrightness + delta))
            UIScreen.main.brightness = nb
            hud = .brightness(nb)
        } else {
            let nv = min(1, max(0, panStartVolume + delta))
            SystemVolumeController.shared.set(nv)
            hud = .volume(nv)
        }
        scheduleHudHide()
    }

    private func handlePanEnd() {
        panAxisSettled = false
        panIsVertical = false
        scheduleHudHide()
    }

    private func startBoost() {
        guard boostRate == nil, !locked, activePanel == nil else { return }
        boostRate = session.rate
        session.setRate(2.0)
        hud = .boost
        scheduleHudHide()
    }

    private func endBoost() {
        guard let r = boostRate else { return }
        boostRate = nil
        session.setRate(r)
        hud = nil
    }

    private func seekRel(_ delta: Double) {
        let pos = session.tick?.position ?? 0
        session.seek(to: max(0, pos + delta))
    }

    private func scheduleHudHide(after: Duration = .milliseconds(900)) {
        hudTask?.cancel()
        hudTask = Task {
            try? await Task.sleep(for: after)
            guard !Task.isCancelled else { return }
            hud = nil
        }
    }

    // MARK: 手势 HUD（屏幕居中反馈）

    @ViewBuilder
    private var gestureHud: some View {
        if let h = hud {
            HStack(spacing: 10) {
                switch h {
                case .seekBack:
                    Image(systemName: "gobackward.10").font(.system(size: 18, weight: .bold))
                    Text("快退 10 秒").hudText
                case .seekForward:
                    Image(systemName: "goforward.10").font(.system(size: 18, weight: .bold))
                    Text("快进 10 秒").hudText
                case .playPause:
                    Image(systemName: session.isPlaying ? "play.fill" : "pause.fill")
                        .font(.system(size: 18, weight: .bold))
                    Text(session.isPlaying ? "继续播放" : "已暂停").hudText
                case .boost:
                    Image(systemName: "gauge.with.needle").font(.system(size: 18, weight: .bold))
                    Text("2× 速览中").hudText
                case .brightness(let v):
                    Image(systemName: "sun.max.fill").font(.system(size: 16, weight: .bold))
                    hudMeter(fraction: v)
                case .volume(let v):
                    Image(systemName: v <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 16, weight: .bold))
                    hudMeter(fraction: CGFloat(v))
                }
            }
            .foregroundStyle(.dsInk)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Capsule().fill(Color.dsGlassFill))
            .overlay(Capsule().strokeBorder(Color.dsGlassBorder))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .animation(.dsSpring, value: hud)
            .allowsHitTesting(false)
        }
    }

    private func hudMeter(fraction: CGFloat) -> some View {
        let f = min(1, max(0, fraction))
        return Capsule().fill(.white.opacity(0.25))
            .frame(width: 110, height: 5)
            .overlay(alignment: .leading) {
                Capsule().fill(.white).frame(width: 110 * f, height: 5)
            }
    }

    // MARK: 锁屏防误触

    /// 控件隐藏后右缘露出小锁：点按锁定（全屏防误触）/ 解锁并还原控件
    private var lockOverlay: some View {
        Button {
            withAnimation(.dsSpring) {
                if locked {
                    locked = false
                    controlsVisible = true
                } else {
                    locked = true
                    controlsVisible = false
                }
            }
        } label: {
            GlassSurface(shape: .capsule, interactive: true) {
                Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.dsInk)
                    .frame(width: 40, height: 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .padding(.trailing, 12)
        .opacity(locked || !controlsVisible ? 1 : 0)
        .allowsHitTesting(locked || !controlsVisible)
        .animation(.dsSpring, value: controlsVisible)
        .animation(.dsSpring, value: locked)
    }

    private var slider: some View {
        let duration = session.tick?.duration ?? 0
        let position = scrubbing ? scrubValue : (session.tick?.position ?? 0)
        let fraction = duration > 0 ? min(1, position / duration) : 0
        return HStack(spacing: 10) {
            Text(timeString(position)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.dsInk)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22)).frame(height: scrubbing ? 6 : 3)
                    Capsule().fill(.white).frame(width: geo.size.width * fraction,
                                                height: scrubbing ? 6 : 3)
                    Circle().fill(.white).frame(width: scrubbing ? 18 : 12, height: scrubbing ? 18 : 12)
                        .offset(x: geo.size.width * fraction - (scrubbing ? 9 : 6))
                        .shadow(color: .black.opacity(scrubbing ? 0.3 : 0), radius: scrubbing ? 4 : 0)
                }
                .animation(.dsSpring, value: scrubbing)
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
            withAnimation(.dsEaseOut) { activePanel = .speed }
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

    /// 上一集/下一集小按钮（顶部条）
    private func epNavButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.dsGlassBorder))
        }
        .foregroundStyle(.dsInk)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
    }

    // MARK: 右侧工具簇（真实功能；锚定在控制条上方，不再用硬偏移）
    private var toolCluster: some View {
        VStack(spacing: 14) {
            toolIcon("text.bubble") {
                withAnimation(.dsEaseOut) { activePanel = .danmaku }
            }
            toolIcon("rectangle.inset.filled.on.rectangle.filled") {
                if session.engine.capabilities.contains(.pip) {
                    session.togglePiP()
                } else {
                    enterMini()
                }
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
                SourceComparePanel(options: activeRequest.options,
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
                          title: "\(activeRequest.title) \(activeRequest.episodeLabel)",
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
            case .speed:
                SpeedPanel(session: session,
                           onClose: { withAnimation(.dsEaseOut) { activePanel = nil } })
            case .episodes:
                EpisodesPanel(titles: activeRequest.episodeTitles ?? [],
                              currentIndex: activeRequest.currentEpisodeIndex,
                              onSelect: { index in Task { await switchEpisode(to: index) } },
                              onClose: { withAnimation(.dsEaseOut) { activePanel = nil } })
            }
        }
    }

    /// 切换剧集：各片源按集序号并发取流 → switchMedia 同引擎重载（渲染上下文不重建），
    /// 旧集进度落盘、新集进度恢复；弹幕重匹配 + 片头片尾标记重载。
    private func switchEpisode(to index: Int) async {
        guard !switchingEpisode else { return }   // 防重入：切集中重复触发直接忽略
        guard let titles = activeRequest.episodeTitles, titles.indices.contains(index),
              index != activeRequest.currentEpisodeIndex else { return }
        switchingEpisode = true
        defer { switchingEpisode = false }
        var options: [StreamOption] = []
        await withTaskGroup(of: StreamOption?.self) { group in
            for base in activeRequest.options {
                guard let fetch = base.episodeStream else { continue }
                group.addTask {
                    do {
                        let info = try await fetch(index)
                        return StreamOption(id: "\(base.id)#\(index)", providerId: base.providerId,
                                            serverName: base.serverName, info: info,
                                            refresh: { try await fetch(index) },
                                            episodeStream: base.episodeStream)
                    } catch {
                        return nil
                    }
                }
            }
            for await o in group { if let o { options.append(o) } }
        }
        let sorted = options.sorted { $0.info.qualityScore > $1.info.qualityScore }
        guard let best = sorted.first else { return }
        let label = titles[index]
        await session.switchMedia(key: "\(activeRequest.title)|\(label)",
                                  to: PlayableItem(url: best.info.url, headers: best.info.headers,
                                                   engine: session.engineKind, startPosition: 0))
        selectedOptionID = best.id
        autoSkipFired = false
        skipMarker = try? env.database.skipMarker(forKey: session.storageKey)
        withAnimation(.dsEaseOut) {
            activeRequest = PlayRequest(title: activeRequest.title, episodeLabel: label,
                                        options: sorted,
                                        episodeTitles: activeRequest.episodeTitles,
                                        currentEpisodeIndex: index)
            activePanel = nil
        }
        danmakuEngine.prepareMatch(title: activeRequest.title, episodeLabel: label)
        await danmakuEngine.autoMatch(title: activeRequest.title,
                                      episodeLabel: label,
                                      client: env.dandanplay)
    }

    /// 换源（进度保留，M4 来源对比；直链有时效的片源先刷新再切换）
    private func switchTo(_ option: StreamOption) async {
        guard option.id != selectedOptionID, !switchingSource else { return }   // 防重入
        switchingSource = true
        defer { switchingSource = false }
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

    /// 手势 HUD 文本样式
    var hudText: some View {
        font(.system(size: 13, weight: .bold))
    }
}

// MARK: - 系统音量写入（iOS 唯一合规途径：窗口内 MPVolumeView 的 UISlider）

/// 隐藏 MPVolumeView 挂在窗口外沿，提供系统音量读写；播放器手势竖滑音量用
@MainActor
final class SystemVolumeController {
    static let shared = SystemVolumeController()
    private let volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 10, height: 10))
    private var sliderRef: UISlider?
    private init() {}

    /// 需先进入窗口层级 MPVolumeView 才生效；onAppear 时调用一次
    func attachIfNeeded() {
        guard volumeView.window == nil else { return }
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        guard let window else { return }
        window.addSubview(volumeView)
        sliderRef = volumeView.subviews.compactMap { $0 as? UISlider }.first
    }

    /// 当前系统音量（0-1）
    var current: Float { AVAudioSession.sharedInstance().outputVolume }

    /// 写入系统音量；UISlider 可能异步装载，每次写入时惰性查找
    func set(_ v: Float) {
        attachIfNeeded()
        let slider = sliderRef ?? volumeView.subviews.compactMap { $0 as? UISlider }.first
        sliderRef = slider
        slider?.setValue(max(0, min(1, v)), animated: false)
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

// MARK: - 浮窗控制层（mpv 无系统 PiP：自绘可拖动小窗 chrome）

/// 浮窗交互层：点击还原全屏、拖动移动位置、底部条播放暂停/还原/关闭。
/// 自身透明，仅负责手势与按钮；视频画面由下层 videoLayer 呈现。
private struct MiniPlayerChrome: View {
    @ObservedObject var session: PlaybackSession
    let size: CGSize
    @Binding var drag: CGSize          // 相对默认停靠点的拖动偏移（容器负责钳制）
    let onExpand: () -> Void
    let onClose: () -> Void

    @State private var dragStart: CGSize?

    var body: some View {
        Color.clear
            .frame(width: size.width, height: size.height)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .bottom) { controls }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22))
            )
            .onTapGesture(perform: onExpand)
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { v in
                        if dragStart == nil { dragStart = drag }
                        drag = CGSize(width: dragStart!.width + v.translation.width,
                                      height: dragStart!.height + v.translation.height)
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }

    private var controls: some View {
        HStack(spacing: 0) {
            Button {
                session.isPlaying ? session.pause() : session.play()
            } label: {
                Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 24)
            }
            Spacer(minLength: 6)
            Button(action: onExpand) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 28, height: 24)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 28, height: 24)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 4)
        .frame(height: 24)
        .background(Color.black.opacity(0.55))
    }
}

// MARK: - 容器尺寸回传

private struct ContainerSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

import SwiftUI
import AVKit

/// 播放器容器：全屏视频层 + 顶部信息条 + 底部控制条 + 右侧工具簇 + 玻璃面板。
/// 视频输出与控制走 PlaybackSession（M2：AVPlayerEngine）。
struct PlayerContainerView: View {
    let target: MockPlayTarget
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var env: AppEnvironment

    @StateObject private var session: PlaybackSession
    @State private var controlsVisible = true
    @State private var activePanel: Panel?
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    init(target: MockPlayTarget) {
        self.target = target
        // 内核自动选择（方案 §3.4）：HLS/MP4→AVPlayer，MKV→mpv；mpv 不可用时回退
        var kind = EngineSelector.recommend(
            container: target.demoURL.pathExtension.isEmpty ? "m3u8" : target.demoURL.pathExtension,
            codec: nil,
            hdr: target.badge.contains("杜比") ? "杜比视界" : nil
        )
        if kind == .mpv && !MPVEngine.isAvailable { kind = .avplayer }
        // M4 接入真实片源后 mediaKey 换成 tmdbKey
        _session = StateObject(wrappedValue: PlaybackSession(
            kind: kind,
            mediaKey: target.title,
            database: AppDatabase.inMemory
        ))
    }

    enum Panel: String { case sources = "来源", danmaku = "弹幕", subtitle = "字幕", cast = "投屏", more = "更多" }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            videoLayer
                .ignoresSafeArea()

            VStack { topBar; Spacer(); controlBar }
            toolCluster
            panelLayer
        }
        .onTapGesture { withAnimation(.dsSpring) { controlsVisible.toggle() } }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task {
            await session.start(PlayableItem(url: target.demoURL, headers: [:],
                                             engine: .avplayer, startPosition: 0))
        }
        .onDisappear { session.close() }
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
                Text(target.title).font(.system(size: 16, weight: .bold)).foregroundStyle(.dsInk)
                Text(target.episode).font(.dsCaption).foregroundStyle(.dsInk2)
                HStack(spacing: 5) {
                    Text(target.badge).badgeStyle(highlight: true)
                    Text("\(target.bitrate) · \(target.container)").font(.dsCaption).foregroundStyle(.dsInk2)
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

    // MARK: 底部控制条
    private var controlBar: some View {
        VStack(spacing: 10) {
            slider
            HStack(spacing: 26) {
                Button {
                    session.isPlaying ? session.pause() : session.play()
                } label: {
                    Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .bold))
                }
                Button { session.seek(to: max(0, (session.tick?.position ?? 0) - 10)) } label: {
                    Image(systemName: "gobackward.10").font(.system(size: 17))
                }
                speedPill
                enginePill
                Spacer()
                panelButton(.cast, icon: "rectangle.on.rectangle")
                pipButton
                panelButton(.sources, icon: "square.stack.3d.up")
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
    }

    // MARK: 右侧工具簇
    private var toolCluster: some View {
        VStack(spacing: 14) {
            toolIcon("text.bubble")
            toolIcon("lock")
            toolIcon("rectangle.on.rectangle")
            toolIcon("ellipsis")
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 18)
        .offset(y: -120)
        .opacity(controlsVisible ? 1 : 0)
        .animation(.dsSpring, value: controlsVisible)
    }

    private func toolIcon(_ name: String) -> some View {
        GlassSurface(shape: .capsule, interactive: true) {
            Image(systemName: name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.dsInk)
                .frame(width: 42, height: 42)
        }
    }

    // MARK: 玻璃面板层
    @ViewBuilder
    private var panelLayer: some View {
        if let panel = activePanel {
            switch panel {
            case .sources:
                SourceComparePanel(sources: target.sources,
                                   selected: .constant(target.sources[1]),
                                   onClose: { withAnimation(.dsEaseOut) { activePanel = nil } })
            case .danmaku:
                DanmakuPanel(onClose: { withAnimation(.dsEaseOut) { activePanel = nil } })
            case .subtitle, .cast, .more:
                GlassPanelSheet(title: panel.rawValue, onClose: { withAnimation(.dsEaseOut) { activePanel = nil } }) {
                    VStack {
                        Text("M3–M6 接入：字幕设置 / 投屏扫描 / 片头片尾·亮度·调试")
                            .font(.dsCaption).foregroundStyle(.dsInk2)
                            .padding(.top, 40)
                        Spacer()
                    }
                }
            }
        }
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

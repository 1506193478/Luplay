import SwiftUI
import UniformTypeIdentifiers

/// 字幕设置面板（方案 §5.2-5 / M3 字幕全家桶 UI）：
/// 音轨/字幕轨选择 + 外挂字幕导入 + 字号/延迟/位置/描边/阴影/ASS 覆盖，
/// 直接写 mpv 属性，偏好存 UserDefaults。
struct SubtitlePanel: View {
    @ObservedObject var session: PlaybackSession
    let onClose: () -> Void

    @State private var fontSize: Double = 38
    @State private var delay: Double = 0
    @State private var position: Double = 100
    @State private var borderWidth: Double = 2
    @State private var shadow: Double = 0
    @State private var overrideASS = false
    @State private var loaded = false
    @State private var selectedAudioID: String?
    @State private var selectedSubtitleID: String?
    @State private var showImporter = false

    private var audioTracks: [TrackInfo] { session.tracks.filter { $0.kind == .audio } }
    private var subtitleTracks: [TrackInfo] { session.tracks.filter { $0.kind == .subtitle } }

    var body: some View {
        GlassPanelSheet(title: "字幕", icon: "textformat.size", onClose: onClose) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if session.engineKind != .mpv {
                        Label("当前内核为 AVPlayer，外挂字幕与样式设置需 mpv 内核生效（右下角内核胶囊可切换）",
                              systemImage: "info.circle")
                            .font(.dsCaption).foregroundStyle(.dsInk2)
                    }
                    trackSection
                    importSection
                    sliderRow("字号", value: $fontSize, range: 20...64, unit: "pt") { v in
                        session.applySubtitleOption(name: "sub-font-size", value: String(Int(v)))
                    }
                    sliderRow("显示区域（底部位置）", value: $position, range: 20...100, unit: "%") { v in
                        session.applySubtitleOption(name: "sub-pos", value: String(Int(v)))
                    }
                    sliderRow("描边宽度", value: $borderWidth, range: 0...5, unit: "") { v in
                        session.applySubtitleOption(name: "sub-border-size", value: String(Int(v)))
                    }
                    sliderRow("阴影", value: $shadow, range: 0...5, unit: "") { v in
                        session.applySubtitleOption(name: "sub-shadow-offset", value: String(Int(v)))
                    }
                    delayRow
                    Toggle(isOn: $overrideASS) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("覆盖 ASS 特效样式").font(.system(size: 14, weight: .semibold)).foregroundStyle(.dsInk)
                            Text("关闭时保留字幕组原始排版（特效字幕推荐关闭）")
                                .font(.dsCaption).foregroundStyle(.dsInk2)
                        }
                    }
                    .tint(.dsAccent)
                    .onChange(of: overrideASS) { _, on in
                        session.applySubtitleOption(name: "sub-ass-override", value: on ? "force" : "no")
                        persist()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 30)
            }
        }
        .onAppear {
            loadPrefs()
            // 打开面板时重读轨道（加载完成后轨道列表才可用）
            session.refreshTracks()
            selectedAudioID = audioTracks.first { $0.isDefault }?.id ?? audioTracks.first?.id
            selectedSubtitleID = subtitleTracks.first { $0.isDefault }?.id ?? subtitleTracks.first?.id
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            importSubtitle(from: url)
        }
    }

    // MARK: 音轨 / 字幕轨选择

    @ViewBuilder
    private var trackSection: some View {
        if !audioTracks.isEmpty || !subtitleTracks.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                if !audioTracks.isEmpty {
                    trackHeader("音轨", icon: "waveform")
                    ForEach(audioTracks) { t in
                        trackRow(t, selected: selectedAudioID == t.id) {
                            selectedAudioID = t.id
                            session.selectAudio(t.id)
                        }
                    }
                }
                if !subtitleTracks.isEmpty {
                    trackHeader("字幕轨", icon: "captions.bubble")
                    ForEach(subtitleTracks) { t in
                        trackRow(t, selected: selectedSubtitleID == t.id) {
                            selectedSubtitleID = t.id
                            session.selectSubtitle(t.id)
                        }
                    }
                    if selectedSubtitleID != nil {
                        Button {
                            selectedSubtitleID = nil
                            session.selectSubtitle(nil)
                        } label: {
                            Label("关闭字幕", systemImage: "eye.slash")
                                .font(.dsCaption).foregroundStyle(.dsInk2)
                        }
                    }
                }
            }
        }
    }

    private func trackHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(.dsAccent)
            Text(title).font(.system(size: 14, weight: .heavy)).foregroundStyle(.dsInk)
        }
    }

    private func trackRow(_ t: TrackInfo, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? Color.accentColor : Color.dsInk3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.name).font(.system(size: 14, weight: .medium)).foregroundStyle(.dsInk)
                        .lineLimit(1)
                    if let lang = t.language, !lang.isEmpty {
                        Text(lang).font(.dsCaption).foregroundStyle(.dsInk2)
                    }
                }
                Spacer()
                if t.isDefault {
                    Text("默认").font(.system(size: 10, weight: .heavy)).foregroundStyle(.dsInk)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.dsGlassBorder))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.dsGlassBorder.opacity(0.5)))
        }
        .buttonStyle(.plain)
    }

    // MARK: 外挂字幕导入（DocumentPicker → mpv sub-add）

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            trackHeader("外挂字幕", icon: "doc.badge.plus")
            Button {
                showImporter = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 15)).foregroundStyle(Color.accentColor)
                    Text("从文件导入字幕（srt / ass / ssa）")
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(Color.accentColor)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12)
                    .fill(Color.accentColor.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
            if session.engineKind != .mpv {
                Text("AVPlayer 内核不支持外挂字幕，切换到 mpv 后生效")
                    .font(.dsCaption).foregroundStyle(.dsInk2)
            }
        }
    }

    /// 文件导入：拷贝到沙盒 tmp 再交给 mpv，避免安全作用域访问生命周期问题
    private func importSubtitle(from url: URL) {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        let ext = (url.lastPathComponent as NSString).pathExtension.lowercased()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("luplay-sub-\(Int(Date().timeIntervalSince1970)).\(ext.isEmpty ? "srt" : ext)")
        try? FileManager.default.removeItem(at: tmp)
        do {
            try FileManager.default.copyItem(at: url, to: tmp)
            session.loadExternalSubtitle(tmp)
        } catch {
            // 拷贝失败（权限/占用）时静默降级：不崩溃，轨道区保持原状
        }
    }

    // MARK: 字幕延迟

    private var delayRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("时间校正").font(.system(size: 14, weight: .semibold)).foregroundStyle(.dsInk)
                Spacer()
                Text(String(format: "%+.1fs", delay))
                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(.dsAccent)
            }
            HStack(spacing: 14) {
                Button {
                    delay = (delay - 0.5).rounded()
                    applyDelay()
                } label: {
                    Image(systemName: "minus.circle.fill").font(.system(size: 24)).foregroundStyle(.dsInk2)
                }
                Slider(value: Binding(
                    get: { delay },
                    set: { delay = ($0 / 0.5).rounded() * 0.5 }
                ), in: -15...15).tint(.dsAccent)
                Button {
                    delay = (delay + 0.5).rounded()
                    applyDelay()
                } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 24)).foregroundStyle(.dsInk2)
                }
            }
            if delay != 0 {
                Button("恢复 0 延迟") { delay = 0; applyDelay() }
                    .font(.dsCaption).foregroundStyle(.dsInk2)
            }
        }
    }

    private func applyDelay() {
        session.applySubtitleOption(name: "sub-delay", value: String(format: "%.1f", delay))
        persist()
    }

    // MARK: 持久化（UserDefaults，非敏感偏好）

    private func loadPrefs() {
        guard !loaded else { return }
        loaded = true
        let d = UserDefaults.standard
        fontSize = d.object(forKey: "sub.fontSize") as? Double ?? 38
        delay = d.object(forKey: "sub.delay") as? Double ?? 0
        position = d.object(forKey: "sub.position") as? Double ?? 100
        borderWidth = d.object(forKey: "sub.borderWidth") as? Double ?? 2
        shadow = d.object(forKey: "sub.shadow") as? Double ?? 0
        overrideASS = d.bool(forKey: "sub.overrideASS")
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(fontSize, forKey: "sub.fontSize")
        d.set(delay, forKey: "sub.delay")
        d.set(position, forKey: "sub.position")
        d.set(borderWidth, forKey: "sub.borderWidth")
        d.set(shadow, forKey: "sub.shadow")
        d.set(overrideASS, forKey: "sub.overrideASS")
    }

    // MARK: 通用滑杆行

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           unit: String, apply: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.dsInk)
                Spacer()
                Text(unit == "pt" || unit == "%" ? "\(Int(value.wrappedValue))\(unit)"
                     : String(format: "%.0f", value.wrappedValue))
                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(.dsAccent)
            }
            Slider(value: Binding(
                get: { value.wrappedValue },
                set: { value.wrappedValue = $0; apply($0); persist() }
            ), in: range).tint(.dsAccent)
        }
    }
}

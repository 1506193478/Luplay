import SwiftUI

/// 字幕设置面板（方案 §5.2-5 / M3 字幕全家桶 UI）：
/// 字号/延迟/垂直位置/描边/阴影/ASS 覆盖，直接写 mpv 属性，偏好存 UserDefaults。
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

    var body: some View {
        GlassPanelSheet(title: "字幕", icon: "textformat.size", onClose: onClose) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if session.engineKind != .mpv {
                        Label("当前内核为 AVPlayer，样式设置需 mpv 内核生效（右下角内核胶囊可切换）",
                              systemImage: "info.circle")
                            .font(.dsCaption).foregroundStyle(.dsInk2)
                    }
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
        .onAppear(perform: loadPrefs)
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

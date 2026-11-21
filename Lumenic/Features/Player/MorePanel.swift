import SwiftUI
import UIKit

/// 更多面板（方案 §5.2-7）：片头片尾标记、自动跳过、亮度调节。
/// 调试信息独立面板（DebugPanel）。
struct MorePanel: View {
    @ObservedObject var session: PlaybackSession
    let database: AppDatabase
    let onOpenDebug: () -> Void
    let onClose: () -> Void

    @State private var marker: SkipMarker = SkipMarker(mediaKey: "", introStart: nil, introEnd: nil, outroStart: nil, autoSkip: true)
    @State private var brightness: Double = UIScreen.main.brightness

    var body: some View {
        GlassPanelSheet(title: "更多", icon: "ellipsis.circle.fill", onClose: onClose) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    skipSection
                    brightnessSection
                    debugSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 30)
            }
        }
        .onAppear { loadMarker() }
        .onChange(of: brightness) { value in
            UIScreen.main.brightness = value
        }
    }

    // MARK: 片头片尾

    private var skipSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("片头片尾", icon: "forward.end.fill")

            HStack(spacing: 10) {
                markerButton("片头起点", value: marker.introStart) {
                    marker.introStart = session.tick?.position
                    saveMarker()
                }
                markerButton("片头结束", value: marker.introEnd) {
                    marker.introEnd = session.tick?.position
                    saveMarker()
                }
                markerButton("片尾起点", value: marker.outroStart) {
                    marker.outroStart = session.tick?.position
                    saveMarker()
                }
            }

            Toggle(isOn: Binding(
                get: { marker.autoSkip },
                set: { marker.autoSkip = $0; saveMarker() }
            )) {
                Text("自动跳过片头/片尾").font(.system(size: 14, weight: .semibold)).foregroundStyle(.dsInk)
            }
            .tint(.dsAccent)

            if marker.introStart != nil || marker.introEnd != nil || marker.outroStart != nil {
                Button {
                    marker = SkipMarker(mediaKey: session.storageKey,
                                        introStart: nil, introEnd: nil, outroStart: nil, autoSkip: true)
                    saveMarker()
                } label: {
                    Text("清除标记").font(.dsCaption)
                        .foregroundStyle(.red.opacity(0.85))
                }
            }
            Text("在合适的时间点按下按钮即可打标；标记按影片保存，下次自动生效")
                .font(.dsCaption).foregroundStyle(.dsInk2)
        }
    }

    private func markerButton(_ label: String, value: Double?, set: @escaping () -> Void) -> some View {
        Button(action: set) {
            VStack(spacing: 3) {
                Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.dsInk)
                Text(value.map { Self.timeString($0) } ?? "未设置")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(value != nil ? Color.dsAccent : Color.dsInk3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.dsGlassBorder))
        }
    }

    // MARK: 亮度

    private var brightnessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("亮度", icon: "sun.max.fill")
            HStack(spacing: 12) {
                Image(systemName: "sun.min").font(.system(size: 12)).foregroundStyle(.dsInk2)
                Slider(value: $brightness, in: 0.05...1).tint(.dsAccent)
                Image(systemName: "sun.max.fill").font(.system(size: 12)).foregroundStyle(.dsInk2)
            }
        }
    }

    // MARK: 调试入口

    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("诊断", icon: "stethoscope")
            Button(action: onOpenDebug) {
                HStack {
                    Image(systemName: "chart.bar.doc.horizontal")
                    Text("打开调试信息面板")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.dsGlassBorder))
            }
            .foregroundStyle(.dsInk)
        }
    }

    // MARK: 持久化

    private func loadMarker() {
        if let saved = try? database.skipMarker(forKey: session.storageKey) {
            marker = saved
        } else {
            marker = SkipMarker(mediaKey: session.storageKey,
                                introStart: nil, introEnd: nil, outroStart: nil, autoSkip: true)
        }
    }

    private func saveMarker() {
        marker.mediaKey = session.storageKey
        try? database.save(skipMarker: marker)
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(.dsAccent)
            Text(title).font(.system(size: 14, weight: .heavy)).foregroundStyle(.dsInk)
        }
    }

    static func timeString(_ t: Double) -> String {
        let total = Int(t), m = total / 60, s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

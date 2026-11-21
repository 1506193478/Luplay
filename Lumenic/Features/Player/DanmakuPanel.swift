import SwiftUI

/// 弹幕玻璃面板（对标参考图：显示开关/自动匹配/密度/字号/粗细/速度/导入）
struct DanmakuPanel: View {
    var onClose: () -> Void

    @State private var showDanmaku = true
    @State private var autoMatch = true
    @State private var opacity: Double = 0.85
    @State private var fontSize: Double = 18
    @State private var area: Double = 0.5

    var body: some View {
        GlassPanelSheet(title: "弹幕", icon: "text.bubble", onClose: onClose) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    toggles
                    steppers
                    importRow
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }
        }
    }

    private var toggles: some View {
        VStack(spacing: 0) {
            toggleRow(icon: "text.bubble", title: "显示弹幕",
                      subtitle: "已暂停显示，挂载记录仍会保留", isOn: $showDanmaku)
            Divider().overlay(Color.dsGlassBorder).padding(.leading, 52)
            toggleRow(icon: "a.circle.fill", title: "自动匹配",
                      subtitle: "进入播放后自动搜索并挂载当前剧集", isOn: $autoMatch)
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.dsGlassBorder.opacity(0.5)))
    }

    @ViewBuilder
    private func toggleRow(icon: String, title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(.dsInk2).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(.dsInk)
                Text(subtitle).font(.dsCaption).foregroundStyle(.dsInk2)
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().tint(.accentColor)
        }
        .padding(14)
    }

    private var steppers: some View {
        VStack(spacing: 0) {
            stepperRow("不透明度", value: Int(opacity * 100), unit: "%",
                       minus: { opacity = max(0.2, opacity - 0.05) },
                       plus: { opacity = min(1, opacity + 0.05) })
            Divider().overlay(Color.dsGlassBorder).padding(.leading, 52)
            stepperRow("字号", value: Int(fontSize), unit: "pt",
                       minus: { fontSize = max(12, fontSize - 1) },
                       plus: { fontSize = min(32, fontSize + 1) })
            Divider().overlay(Color.dsGlassBorder).padding(.leading, 52)
            stepperRow("显示区域", value: Int(area * 100), unit: "%",
                       minus: { area = max(0.25, area - 0.25) },
                       plus: { area = min(1.0, area + 0.25) })
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.dsGlassBorder.opacity(0.5)))
    }

    @ViewBuilder
    private func stepperRow(_ title: String, value: Int, unit: String, minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 15)).foregroundStyle(.dsInk)
            Spacer()
            HStack(spacing: 10) {
                stepButton("minus", action: minus)
                Text("\(value) \(unit)")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.dsInk)
                    .frame(minWidth: 56)
                stepButton("plus", action: plus)
            }
        }
        .padding(14)
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.dsInk)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.dsGlassBorder))
        }
    }

    private var importRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down").font(.system(size: 15)).foregroundStyle(.dsInk2)
            Text("导入本地弹幕文件").font(.system(size: 15)).foregroundStyle(.dsInk)
            Spacer()
            Text("B站 XML / 弹弹play JSON").font(.dsCaption).foregroundStyle(.dsInk3)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.dsGlassBorder.opacity(0.5)))
    }
}

import SwiftUI

/// 倍速选择面板：0.5x–3.0x 三列网格，当前倍速高亮
struct SpeedPanel: View {
    @ObservedObject var session: PlaybackSession
    let onClose: () -> Void

    static let rates: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    var body: some View {
        GlassPanelSheet(title: "倍速", icon: "gauge.with.dots.needle.bottom.50percent", onClose: onClose) {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                          spacing: 12) {
                    ForEach(Self.rates, id: \.self) { rate in
                        rateCell(rate)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 30)
            }
        }
    }

    private func rateCell(_ rate: Double) -> some View {
        let selected = abs(session.rate - rate) < 0.001
        return Button {
            session.setRate(rate)
        } label: {
            Text("\(String(format: "%g", rate))×")
                .font(.system(size: 16, weight: selected ? .heavy : .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14)
                    .fill(selected ? Color.dsAccent.opacity(0.18) : Color.dsGlassBorder))
        }
        .foregroundStyle(selected ? Color.dsAccent : Color.dsInk)
    }
}

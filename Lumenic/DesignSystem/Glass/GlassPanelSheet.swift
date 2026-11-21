import SwiftUI

/// 统一玻璃面板容器：底部滑出的玻璃 Sheet（来源/弹幕/字幕/投屏等全部复用）。
/// 自绘 overlay 实现（非 .sheet），保证玻璃形态与形变自由度，iOS 16 可用。
struct GlassPanelSheet<Content: View>: View {
    var title: String
    var icon: String = "bubble.left.and.bubble.right.fill"
    var showClose: Bool = true
    var onClose: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .top) {
            // 背景压暗（点击关闭）
            Color.black.opacity(appeared ? 0.35 : 0)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(spacing: 0) {
                grabber
                header
                Divider().overlay(Color.dsGlassBorder)
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: 560)
            .background(
                GlassSimulatorBackground(
                    shape: AnyShape(erasing: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24)),
                    tint: .dsGlassFill
                )
            )
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .onAppear {
            withAnimation(.dsEaseOut) { appeared = true }
        }
    }

    private var grabber: some View {
        Capsule()
            .fill(Color.white.opacity(0.28))
            .frame(width: 36, height: 5)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.dsInk)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.dsGlassBorder))

            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.dsInk)

            Spacer()

            if showClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.dsInk)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.dsGlassBorder))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// UnevenRoundedRectangle 双参便捷初始化（iOS 16.0+ 自带四参版本）
extension UnevenRoundedRectangle {
    init(topLeadingRadius: CGFloat, topTrailingRadius: CGFloat) {
        self.init(
            topLeadingRadius: topLeadingRadius,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: topTrailingRadius,
            style: .continuous
        )
    }
}

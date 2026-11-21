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
    @State private var dragOffset: CGFloat = 0   // 下拉关闭手势偏移

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // 背景压暗（点击关闭）
                Color.black.opacity(appeared && dragOffset == 0 ? 0.35 : (appeared ? 0.15 : 0))
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
                // 高度上限取 min(560, 可用高度 92%)：横屏（高约 390pt）不再顶出屏幕
                .frame(maxHeight: min(560, geo.size.height * 0.92))
                .background(
                    GlassSimulatorBackground(
                        shape: AnyShape(erasing: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24)),
                        tint: .dsGlassFill
                    )
                )
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
                // 下拉跟随，松手超阈值关闭（把手/标题区拖动，不干扰内容滚动）
                .offset(y: max(0, dragOffset))
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        // 进出场：底部滑入/滑出（panelLayer 插拔时由 withAnimation 驱动）
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onAppear {
            withAnimation(.dsEaseOut) { appeared = true }
        }
    }

    /// 下拉关闭手势：仅挂在把手+标题区，避免与面板内 ScrollView 冲突
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { v in
                guard v.translation.height > 0 else { return }
                dragOffset = v.translation.height
            }
            .onEnded { v in
                if v.translation.height > 120 || v.predictedEndTranslation.height > 260 {
                    dragOffset = 0
                    onClose()
                } else {
                    withAnimation(.dsSpring) { dragOffset = 0 }
                }
            }
    }

    private var grabber: some View {
        Capsule()
            .fill(Color.white.opacity(0.28))
            .frame(width: 36, height: 5)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity)   // 整条顶带都可下拉
            .contentShape(Rectangle())
            .gesture(dismissDrag)
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
        .background(Color.clear)
        .contentShape(Rectangle())
        .gesture(dismissDrag)
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

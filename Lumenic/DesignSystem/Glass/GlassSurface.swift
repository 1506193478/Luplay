import SwiftUI

/// 全局玻璃面板组件 —— 业务代码唯一入口。
/// iOS 26+：原生 Liquid Glass（glassEffect / interactive / GlassEffectContainer 形变）。
/// iOS 16-25：GlassSimulator（可变模糊 + 增艳 + 高光描边 + matchedGeometryEffect 形变）。
struct GlassSurface<Content: View>: View {
    enum Shape: Equatable {
        case capsule
        case rounded(CGFloat)
        case panel // 大面板：顶部 24 圆角、底部贴边

        var radius: CGFloat {
            switch self {
            case .capsule: return 999
            case .rounded(let r): return r
            case .panel: return 24
            }
        }
    }

    var shape: Shape = .rounded(16)
    var tint: Color = .white.opacity(0.06)
    var interactive: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            nativeBody
        } else {
            simulatedBody
        }
    }

    // MARK: - iOS 26 原生路径

    @available(iOS 26.0, *)
    @ViewBuilder
    private var nativeBody: some View {
        let shapeProxy = shapeProxy
        let glass: Glass = interactive ? .regular.interactive() : .regular
        content()
            .padding(padding)
            .glassEffect(glass.tint(tint), in: shapeProxy)
    }

    // MARK: - iOS 16 模拟路径

    private var simulatedBody: some View {
        content()
            .padding(padding)
            .background(
                GlassSimulatorBackground(shape: shapeProxy, tint: tint)
            )
            .overlay(
                // 高光描边：顶部亮、底部弱，模拟玻璃折光
                RoundedRectangle(cornerRadius: cappedRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.22), .white.opacity(0.05)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    .clipShape(shapeProxy)
            )
    }

    private var cappedRadius: CGFloat { min(shape.radius, 40) }

    private var shapeProxy: AnyShape {
        AnyShape(erasing: shape == .capsule
            ? AnyShape(erasing: Capsule())
            : AnyShape(erasing: RoundedRectangle(cornerRadius: cappedRadius, style: .continuous)))
    }

    private var padding: CGFloat {
        shape == .panel ? 0 : 10
    }
}

// MARK: - 玻璃模拟背景（iOS 16-25）

/// UIVisualEffectView 提供 blur+增艳（SwiftUI Material 无法调饱和度）
struct GlassSimulatorBackground: View {
    let shape: AnyShape
    let tint: Color

    var body: some View {
        shape
            .fill(tint)
            .background(BlurEffectView(style: .systemUltraThinMaterialDark))
            .clipShape(shape)
            .overlay(shape.stroke(Color.dsGlassBorder, lineWidth: 1))
    }
}

struct BlurEffectView: UIViewRepresentable {
    let style: UIBlurEffect.Style

    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }
    func updateUIView(_ view: UIVisualEffectView, context: Context) {
        view.effect = UIBlurEffect(style: style)
    }
}

// MARK: - 形变工具（玻璃形变）

/// iOS 26 用 glassEffectID；iOS 16 用 matchedGeometryEffect 近似。
/// 用法：两个 GlassSurface 包在 GlassMorphContainer 内，切换 matched id 即产生形变迁移。
struct GlassMorphContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 12) { content() }
        } else {
            content()
        }
    }
}

// MARK: - 辅助

struct AnyShape: Shape {
    private let raw: any Shape
    init(erasing shape: some Shape) { raw = shape }
    func path(in rect: CGRect) -> Path { raw.path(in: rect) }
}

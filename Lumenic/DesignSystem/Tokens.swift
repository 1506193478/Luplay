import SwiftUI

// 设计 token：源自 lumenic-home.html 原型
extension Color {
    /// 主文字 rgba(245,241,234)
    static let dsInk = Color(red: 0.96, green: 0.95, blue: 0.92)
    /// 次级文字
    static let dsInk2 = Color.white.opacity(0.52)
    /// 弱文字
    static let dsInk3 = Color.white.opacity(0.30)
    /// 玻璃底色 rgba(30,26,22,.55)
    static let dsGlassFill = Color(red: 0.12, green: 0.10, blue: 0.09).opacity(0.55)
    /// 玻璃描边 rgba(255,255,255,.10)
    static let dsGlassBorder = Color.white.opacity(0.10)
    /// 页面底色
    static let dsPage = Color(red: 0.08, green: 0.06, blue: 0.04)
    /// 卡片底色 #241d15
    static let dsCard = Color(red: 0.141, green: 0.114, blue: 0.082)

    // 浅色页（稿 lpage：v-prov/v-edit/v-set）
    static let dsLightPage = Color(red: 0.957, green: 0.945, blue: 0.922)   // #f4f1eb
    static let dsLightCard = Color.white
    static let dsLightInk = Color(red: 0.13, green: 0.11, blue: 0.09)
    static let dsLightInk2 = Color(red: 0.45, green: 0.42, blue: 0.38)
    static let dsLightBorder = Color.black.opacity(0.08)
    /// 评分金
    static let dsGold = Color(red: 1.0, green: 0.84, blue: 0.04)
    /// 强调色（方案 §5.3：iOS 系统蓝 #0A84FF）
    static let dsAccent = Color(red: 0.039, green: 0.518, blue: 1.0)
}

// 让 .dsInk 等前缀写法在 ShapeStyle 泛型位置（foregroundStyle/fill/stroke/tint/background）
// 稳定可解析：Release WMO 下部分上下文会退化为 any ShapeStyle 查找而报错
extension ShapeStyle where Self == Color {
    static var dsInk: Color { Color.dsInk }
    static var dsInk2: Color { Color.dsInk2 }
    static var dsInk3: Color { Color.dsInk3 }
    static var dsGlassFill: Color { Color.dsGlassFill }
    static var dsGlassBorder: Color { Color.dsGlassBorder }
    static var dsPage: Color { Color.dsPage }
    static var dsCard: Color { Color.dsCard }
    static var dsLightPage: Color { Color.dsLightPage }
    static var dsLightCard: Color { Color.dsLightCard }
    static var dsLightInk: Color { Color.dsLightInk }
    static var dsLightInk2: Color { Color.dsLightInk2 }
    static var dsLightBorder: Color { Color.dsLightBorder }
    static var dsGold: Color { Color.dsGold }
    static var dsAccent: Color { Color.dsAccent }
}

extension Font {
    static let dsTitle = Font.system(size: 26, weight: .heavy)
    static let dsSection = Font.system(size: 21, weight: .heavy)
    static let dsCardTitle = Font.system(size: 13.5, weight: .semibold)
    static let dsCaption = Font.system(size: 11)
}

/// 全局弹簧曲线（原型 --spring）
extension Animation {
    static let dsSpring = Animation.spring(response: 0.32, dampingFraction: 0.7)
    static let dsEaseOut = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.43)
}

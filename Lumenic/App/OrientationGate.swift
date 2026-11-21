import UIKit

/// 横屏方向闸门：AppDelegate 按此状态动态返回支持方向。
/// 仅播放器存活期（fullScreenCover 显示中）放行横屏，其余界面保持竖屏；
/// 关闭播放器时强制旋回竖屏，与设备物理朝向无关。
final class OrientationGate {
    static let shared = OrientationGate()

    /// true = 允许横屏（PlayerContainerView onAppear 置 true，onDisappear 置 false）
    var allowLandscape: Bool = false {
        didSet {
            guard allowLandscape != oldValue else { return }
            refreshSupportedOrientations()
        }
    }

    /// 通知 UIKit 重新评估方向（iOS 16+ geometry API）：
    /// - 放行横屏时按设备当前物理朝向就近旋转（手机横握即进横屏）
    /// - 收紧为竖屏时强制旋回 Portrait
    private func refreshSupportedOrientations() {
        let target: UIInterfaceOrientationMask = allowLandscape ? .allButUpsideDown : .portrait
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: target))
            scene.windows.forEach { $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
        }
    }
}

/// 全局方向仲裁：闸门开 → 全方向（不含倒置），闸门关 → 仅竖屏。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationGate.shared.allowLandscape ? .allButUpsideDown : .portrait
    }
}

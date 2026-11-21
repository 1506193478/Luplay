import SwiftUI

@main
struct LuplayApp: App {
    // 方向仲裁：播放页放行横屏，其余页面竖屏（见 OrientationGate）
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(env)
                .preferredColorScheme(.dark) // 原型基准为深色；设置页后续可切换
        }
    }
}

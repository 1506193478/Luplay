import SwiftUI

@main
struct LuplayApp: App {
    @StateObject private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(env)
                .preferredColorScheme(.dark) // 原型基准为深色；设置页后续可切换
        }
    }
}

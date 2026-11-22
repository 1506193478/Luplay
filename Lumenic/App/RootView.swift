import SwiftUI

/// 自定义玻璃 Tab 栏（iOS16 无系统玻璃，统一走 GlassSurface）
struct RootView: View {
    enum Tab: Int, CaseIterable { case home, library, search, settings }

    @State private var tab: Tab = .home
    @State private var playerSession: PlayerSession?
    @State private var playerMini = false   // 播放器浮窗模式（mpv 小窗与 Tab 共存）

    /// 播放器全屏接管中（浮窗模式下 Tab 栏恢复可用）
    private var playerFullscreen: Bool { playerSession != nil && !playerMini }

    var body: some View {
        ZStack(alignment: .bottom) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 播放器常驻 overlay（非 fullScreenCover）：
            // 全屏/浮窗是同一渲染视图的几何切换，mpv GL 渲染上下文不销毁
            if let session = playerSession {
                PlayerContainerView(request: session.request,
                                    mini: $playerMini,
                                    onClose: { withAnimation(.dsEaseOut) { playerSession = nil } })
                    .id(session.id)   // 每次新开播放器强制重建（StateObject 会话不串场）
                    .transition(.opacity)
                    .zIndex(1)
            }

            tabBar
                .opacity(playerFullscreen ? 0 : 1)
                .allowsHitTesting(!playerFullscreen)
                .animation(.dsEaseOut, value: playerFullscreen)
                .zIndex(2)
        }
        .ignoresSafeArea(.keyboard)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .home:
            HomeView(openPlayer: play(_:),
                     openSearch: { switchTo(.search) },
                     openSettings: { switchTo(.settings) })
        case .library: LibraryView()
        case .search: SearchView(openPlayer: play(_:))
        case .settings: SettingsView()
        }
    }

    private func switchTo(_ t: Tab) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { tab = t }
    }

    private func play(_ request: PlayRequest) {
        playerMini = false
        withAnimation(.dsEaseOut) { playerSession = PlayerSession(request: request) }
    }

    private var tabBar: some View {
        GlassSurface(shape: .capsule, interactive: true) {
            HStack(spacing: 0) {
                tabButton(.home, icon: "house.fill", label: "首页")
                tabButton(.library, icon: "square.grid.2x2.fill", label: "媒体库")
                tabButton(.search, icon: "magnifyingglass", label: "搜索")
                tabButton(.settings, icon: "gearshape.fill", label: "设置")
            }
            // 不加内层 vertical padding：玻璃自带 10pt 内边距，
            // 内容(图标21+间距3+标签12=36)在 62pt 外框下垂直居中不溢出
        }
        .frame(height: 62)
        .padding(.bottom, 18)
        .padding(.horizontal, 40)
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }

    private func tabButton(_ t: Tab, icon: String, label: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { tab = t }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                Text(label).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(tab == t ? Color.accentColor : .dsInk2)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

/// 播放器入口会话（持有真实片源播放请求）
struct PlayerSession: Identifiable {
    let id = UUID()
    let request: PlayRequest
}

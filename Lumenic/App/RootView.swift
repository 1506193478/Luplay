import SwiftUI

/// 自定义玻璃 Tab 栏（iOS16 无系统玻璃，统一走 GlassSurface）
struct RootView: View {
    enum Tab: Int, CaseIterable { case home, library, search, settings }

    @State private var tab: Tab = .home
    @State private var playerSession: PlayerSession?

    var body: some View {
        ZStack(alignment: .bottom) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            tabBar
                .padding(.bottom, 18)
                .padding(.horizontal, 40)
        }
        .ignoresSafeArea(.keyboard)
        .fullScreenCover(item: $playerSession) { session in
            PlayerContainerView(request: session.request)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .home: HomeView(openPlayer: play(_:))
        case .library: LibraryView()
        case .search: SearchView(openPlayer: play(_:))
        case .settings: SettingsView()
        }
    }

    private func play(_ request: PlayRequest) {
        playerSession = PlayerSession(request: request)
    }

    private var tabBar: some View {
        GlassSurface(shape: .capsule, interactive: true) {
            HStack(spacing: 0) {
                tabButton(.home, icon: "house.fill", label: "首页")
                tabButton(.library, icon: "square.grid.2x2.fill", label: "媒体库")
                tabButton(.search, icon: "magnifyingglass", label: "搜索")
                tabButton(.settings, icon: "gearshape.fill", label: "设置")
            }
            .padding(.vertical, 10)
        }
        .frame(height: 62)
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

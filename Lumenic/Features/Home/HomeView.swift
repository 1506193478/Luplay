import SwiftUI

/// 首页：hero 轮播 + 继续观看 + 我的媒体库 + 热门，对标 lumenic-home.html
struct HomeView: View {
    var openPlayer: (PlayRequest) -> Void = { _ in }
    @EnvironmentObject private var env: AppEnvironment
    @State private var heroIndex = 0
    @State private var progressEntries: [PlaybackProgress] = []
    @State private var loadedProgress = false

    var body: some View {
        ZStack(alignment: .top) {
            // 整页背景 = 当前 hero 封面模糊放大
            CoverPlaceholder(gradient: MockStore.hero[heroIndex].gradient)
                .blur(radius: 44)
                .scaleEffect(1.25)
                .ignoresSafeArea()
                .overlay(Color.dsPage.opacity(0.35).ignoresSafeArea())
                .animation(.easeInOut(duration: 0.9), value: heroIndex)
                .id(heroIndex)
                .transition(.opacity)

            ScrollView(showsIndicators: false) {
                hero
                continueWatching
                librarySection
                popularSection
                Color.clear.frame(height: 120)
            }
            .ignoresSafeArea(edges: .top)
        }
        .overlay(alignment: .top) { topBar }
        .overlay(alignment: .bottomTrailing) { fab }
    }

    // MARK: 顶栏（大标题 + 服务胶囊）
    private var topBar: some View {
        HStack(alignment: .bottom) {
            Text("Luplay")
                .font(.dsTitle)
                .foregroundStyle(.dsInk)
                .shadow(color: .black.opacity(0.5), radius: 10)
            Spacer()
            GlassSurface(shape: .capsule, interactive: true) {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(colors: [.green, .green.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 20, height: 20)
                        .overlay(Text("E").font(.system(size: 11, weight: .bold)).foregroundStyle(.white))
                    Text(env.providers.count > 1 ? env.providers[0].displayName : "未配置片源")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(.dsInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text("\(env.providers.count) 源")
                        .font(.dsCaption)
                        .foregroundStyle(.dsInk2)
                }
            }
            .frame(maxWidth: 230, minHeight: 40)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    // MARK: Hero 轮播
    private var hero: some View {
        VStack(spacing: 8) {
            TabView(selection: $heroIndex) {
                ForEach(Array(MockStore.hero.enumerated()), id: \.1.id) { i, m in
                    ZStack(alignment: .bottomLeading) {
                        CoverPlaceholder(gradient: m.gradient)
                        LinearGradient(colors: [.clear, .dsPage.opacity(0.9)], startPoint: .center, endPoint: .bottom)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(m.title)
                                .font(.system(size: 34, weight: .bold))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.6), radius: 12)
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                            Text(m.subtitle)
                                .font(.dsCaption)
                                .foregroundStyle(.white.opacity(0.72))
                                .lineLimit(1)
                        }
                        .padding(22)
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 400)
            .onChange(of: heroIndex) { _ in } // TabView 自带滑动切换

            HStack(spacing: 5) {
                ForEach(0..<MockStore.hero.count, id: \.self) { i in
                    Capsule()
                        .fill(heroIndex == i ? Color.white : .white.opacity(0.38))
                        .frame(width: heroIndex == i ? 17 : 5, height: 5)
                        .animation(.dsSpring, value: heroIndex)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
        }
        .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .init(x: 0.5, y: 0), endPoint: .init(x: 0.5, y: 0.96)))
    }

    // MARK: 继续观看（真实进度库；无记录时落演示数据）
    private var continueWatching: some View {
        section("继续观看") {
            if progressEntries.isEmpty {
                ForEach(MockStore.continueWatching) { m in
                    VStack(alignment: .leading, spacing: 7) {
                        CoverPlaceholder(gradient: m.gradient)
                            .frame(width: 202, height: 113)
                            .clipShape(RoundedRectangle(cornerRadius: 13))
                        Text(m.title).font(.dsCardTitle).foregroundStyle(.dsInk)
                            .lineLimit(1).minimumScaleFactor(0.85)
                            .frame(maxWidth: 202, alignment: .leading)
                        Text(m.subtitle).font(.dsCaption).foregroundStyle(.dsInk2)
                            .lineLimit(1)
                            .frame(maxWidth: 202, alignment: .leading)
                    }
                    .onTapGesture { openPlayer(PlayRequest.demo()) }
                }
            } else {
                ForEach(progressEntries, id: \.tmdbKey) { entry in
                    resumeRow(entry)
                }
            }
        }
        .task {
            guard !loadedProgress else { return }
            loadedProgress = true
            progressEntries = (try? env.database.allProgress()) ?? []
        }
    }

    /// 进度条目卡片：封面渐变 + 剩余时间 + 进度条；点击续播（媒体 key 对齐，自动恢复进度）
    private func resumeRow(_ entry: PlaybackProgress) -> some View {
        let parts = entry.tmdbKey.split(separator: "|", maxSplits: 1).map(String.init)
        let title = parts.first ?? entry.tmdbKey
        let episodeLabel = parts.count > 1 ? parts[1] : "正片"
        let fraction = entry.duration > 0 ? min(1, entry.position / entry.duration) : 0
        let remaining = max(0, entry.duration - entry.position)
        return VStack(alignment: .leading, spacing: 7) {
            CoverPlaceholder(gradient: CoverPalette.forTitle(title))
                .frame(width: 202, height: 113)
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .overlay(alignment: .bottomLeading) {
                    Text(remaining > 60 ? "还剩 \(Self.timeText(remaining))" : "即将看完")
                        .font(.system(size: 10.5))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(.black.opacity(0.5)))
                        .padding(9)
                }
                .overlay(alignment: .bottom) {
                    GeometryReader { geo in
                        Capsule().fill(.white.opacity(0.22))
                            .overlay(alignment: .leading) {
                                Capsule().fill(Color.dsAccent).frame(width: geo.size.width * fraction)
                            }
                    }
                    .frame(height: 3)
                }
            Text(title).font(.dsCardTitle).foregroundStyle(.dsInk)
                .lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: 202, alignment: .leading)
            Text(episodeLabel).font(.dsCaption).foregroundStyle(.dsInk2)
                .lineLimit(1)
                .frame(maxWidth: 202, alignment: .leading)
        }
        .onTapGesture { openPlayer(PlayRequest.demoResuming(title: title, episodeLabel: episodeLabel)) }
    }

    private static func timeText(_ t: Double) -> String {
        let total = Int(t), m = total / 60, s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: 媒体库
    private var librarySection: some View {
        section("我的媒体库", more: "管理") {
            ForEach(MockStore.libraries, id: \.0) { item in
                VStack(alignment: .leading, spacing: 7) {
                    CoverPlaceholder(gradient: [item.2, .black])
                        .frame(width: 148, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 13))
                        .overlay(alignment: .bottomLeading) {
                            Text(item.0).font(.system(size: 14, weight: .heavy)).foregroundStyle(.white).padding(11)
                        }
                    Text(item.1).font(.dsCaption).foregroundStyle(.dsInk2)
                }
            }
        }
    }

    // MARK: 热门
    private var popularSection: some View {
        section("热门推荐", more: "更多") {
            ForEach(MockStore.popular) { m in
                VStack(alignment: .leading, spacing: 7) {
                    CoverPlaceholder(gradient: m.gradient)
                        .frame(width: 112, height: 158)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(alignment: .topTrailing) {
                            if let n = m.episodeCount {
                                Text("更新至\(n)集")
                                    .font(.system(size: 10.5, weight: .heavy))
                                    .padding(.horizontal, 6)
                                    .frame(height: 22)
                                    .background(Capsule().fill(.black.opacity(0.55)))
                                    .foregroundStyle(.white)
                                    .padding(7)
                            }
                        }
                        .overlay(alignment: .bottomLeading) {
                            if let s = m.score {
                                Text(String(format: "%.1f", s))
                                    .font(.system(size: 10.5, weight: .heavy))
                                    .foregroundStyle(.dsGold)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(.black.opacity(0.5)))
                                    .padding(7)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            Text(m.title)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.65), radius: 8)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .padding(.horizontal, 6)
                                .padding(.bottom, 24)
                        }
                    Text(m.subtitle).font(.dsCaption).foregroundStyle(.dsInk2).lineLimit(1)
                        .frame(maxWidth: 112, alignment: .leading)
                }
                .onTapGesture { openPlayer(PlayRequest.demo()) }
            }
        }
    }

    // MARK: 通用分区
    @ViewBuilder
    private func section<Content: View>(_ title: String, more: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.dsSection).foregroundStyle(.dsInk)
                Spacer()
                if let more {
                    HStack(spacing: 2) {
                        Text(more)
                        Image(systemName: "chevron.right").font(.system(size: 9))
                    }
                    .font(.system(size: 12.5))
                    .foregroundStyle(.dsInk2)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 10)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 11) { content() }
                    .padding(.horizontal, 20)
            }
        }
    }

    // MARK: 搜索 FAB
    private var fab: some View {
        GlassSurface(shape: .capsule, interactive: true) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.dsInk)
                .frame(width: 54, height: 54)
        }
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
        .padding(.trailing, 18)
        .padding(.bottom, 96)
    }
}

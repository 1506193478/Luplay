import SwiftUI

/// 聚合搜索：搜索框 + 多片源并发检索 + TMDB 归一化合并（M4 接通真实片源）
struct SearchView: View {
    var openPlayer: (PlayRequest) -> Void = { _ in }
    @EnvironmentObject private var env: AppEnvironment
    @State private var query = ""
    @State private var searched = false
    @State private var detailTarget: SearchAggregator.AggregatedResult?
    @State private var showURLPanel = false

    private var aggregator: SearchAggregator { env.aggregator }

    var body: some View {
        VStack(spacing: 0) {
            searchBar.padding(.horizontal, 16).padding(.top, 10)
            urlEntry.padding(.horizontal, 16).padding(.top, 10)
            if !searched {
                hotList
            } else {
                resultList
            }
            Spacer(minLength: 0)
        }
        .background(Color.dsPage.ignoresSafeArea())
        .sheet(item: $detailTarget) { result in
            AggregateDetailView(result: result, onPlay: { request in
                detailTarget = nil
                openPlayer(request)
            })
            .presentationDetents([.large])
        }
        // 链接播放玻璃面板（底部滑入，与播放器内面板同一容器）
        .overlay(alignment: .bottom) {
            if showURLPanel {
                URLPlayPanel(onPlay: { openPlayer($0) },
                             onClose: { withAnimation(.dsEaseOut) { showURLPanel = false } })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(10)
            }
        }
    }

    /// 网络链接播放入口：粘贴直链 → 解析 → 播放
    private var urlEntry: some View {
        Button {
            withAnimation(.dsEaseOut) { showURLPanel = true }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "link")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.dsInk)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.dsGlassBorder))
                VStack(alignment: .leading, spacing: 2) {
                    Text("链接播放").font(.system(size: 15, weight: .semibold)).foregroundStyle(.dsInk)
                    Text("粘贴网络视频直链，解析后立即播放").font(.dsCaption).foregroundStyle(.dsInk2)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.dsInk3).font(.system(size: 13))
            }
            .padding(10)
            .background(GlassSurface(shape: .rounded(16)) { Color.clear })
        }
        .buttonStyle(.plain)
    }

    private var searchBar: some View {
        GlassSurface(shape: .rounded(14), interactive: true) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.dsInk2)
                TextField("搜索片名，聚合全部片源", text: $query)
                    .foregroundStyle(.dsInk)
                    .onSubmit { runSearch() }
                if !query.isEmpty {
                    Button {
                        query = ""
                        searched = false
                        aggregator.results = []
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.dsInk3)
                    }
                }
            }
            .font(.system(size: 15))
        }
        .frame(height: 48)
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        withAnimation(.dsEaseOut) { searched = true }
        Task { await aggregator.search(query: q, providers: env.providers) }
    }

    private var hotList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("热门搜索").font(.dsSection).foregroundStyle(.dsInk)
                .padding(.horizontal, 20).padding(.top, 22)
            ForEach(["蚀骨时差", "好东西", "星际回声", "漫长的季节"], id: \.self) { kw in
                Button {
                    query = kw
                    runSearch()
                } label: {
                    HStack {
                        Image(systemName: "flame.fill").foregroundStyle(.orange)
                        Text(kw).foregroundStyle(.dsInk)
                        Spacer()
                        Text("聚合搜索").font(.dsCaption).foregroundStyle(.dsInk3)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 10)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var resultList: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                if aggregator.isSearching {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在聚合全部片源…").font(.dsCaption).foregroundStyle(.dsInk2)
                    }
                    .padding(.top, 60)
                } else if aggregator.results.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "film.stack").font(.system(size: 30)).foregroundStyle(.dsInk3)
                        Text("没有命中结果")
                            .font(.system(size: 15, weight: .medium)).foregroundStyle(.dsInk2)
                        Text("确认已在设置中配置并登录片源服务器")
                            .font(.dsCaption).foregroundStyle(.dsInk3)
                    }
                    .padding(.top, 60)
                } else {
                    ForEach(aggregator.results) { result in
                        Button { detailTarget = result } label: { aggregateCard(result) }
                    }
                }
                Color.clear.frame(height: 120)
            }
            .padding(.horizontal, 16).padding(.top, 14)
        }
    }

    /// 聚合结果卡：归一化标题 + 命中的片源徽章
    private func aggregateCard(_ result: SearchAggregator.AggregatedResult) -> some View {
        HStack(spacing: 12) {
            ResultPoster(title: result.title)
                .frame(width: 86, height: 118)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 6) {
                Text(result.title).font(.system(size: 17, weight: .bold)).foregroundStyle(.dsInk)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text("\(result.items.count) 个片源命中")
                    .font(.dsCaption).foregroundStyle(.dsInk2)
                Spacer()
                HStack(spacing: 6) {
                    let names = result.items.compactMap { item in
                        env.providers.first { $0.id == item.providerId }?.displayName
                    }
                    ForEach(Array(Set(names).sorted().prefix(3)), id: \.self) { name in
                        sourceBadge(name)
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(.dsInk3).font(.system(size: 13))
        }
        .padding(12)
        .background(GlassSurface(shape: .rounded(16)) { Color.clear })
    }

    private func sourceBadge(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.85)))
    }
}

// MARK: - TMDB 海报（未配置/查不到时落渐变占位）

private struct ResultPoster: View {
    let title: String
    @EnvironmentObject private var env: AppEnvironment
    @State private var url: URL?

    var body: some View {
        ZStack {
            if let url {
                AsyncImage(url: url) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFill()
                    } else {
                        CoverPlaceholder(gradient: CoverPalette.forTitle(title))
                    }
                }
            } else {
                CoverPlaceholder(gradient: CoverPalette.forTitle(title))
            }
        }
        .task { url = await env.tmdb.posterURL(title: title, year: nil) }
    }
}

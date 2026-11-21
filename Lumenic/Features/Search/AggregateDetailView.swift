import SwiftUI

/// 聚合详情页：归一化标题 + 多片源（电影直接播放 / 剧集选集后多源对比播放）
struct AggregateDetailView: View {
    let result: SearchAggregator.AggregatedResult
    var onPlay: (PlayRequest) -> Void

    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var expandedSeriesID: String?
    @State private var episodeCache: [String: [Episode]] = [:]   // itemId → 集列表
    @State private var isFetching = false
    @State private var errorText: String?
    @State private var backdropURL: URL?

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    backdrop
                    titleSection
                    movieSection
                    seriesSection
                    if let errorText {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(errorText)
                        }
                        .font(.dsCaption).foregroundStyle(.orange)
                        .padding(.horizontal, 20).padding(.top, 12)
                    }
                    Color.clear.frame(height: 140)
                }
            }
            .ignoresSafeArea(edges: .top)

            if isFetching {
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("正在获取播放地址…").font(.dsCaption).foregroundStyle(.dsInk)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(GlassSurface(shape: .capsule) { Color.clear })
                .padding(.bottom, 40)
            }
        }
        .overlay(alignment: .topLeading) { navBack }
        // 进媒体库（upsert）：打开过详情即收藏，记录归一化 key / 标题 / 命中片源 / 海报
        .task {
            let ids = Array(Set(result.items.map(\.providerId))).sorted()
            let poster = await env.tmdb.posterURL(title: result.title, year: nil)
            try? env.database.save(libraryEntry: LibraryEntry(
                tmdbKey: result.id, title: result.title, providerIds: ids,
                posterPath: poster?.absoluteString, addedAt: Date()))
        }
    }

    private var backdrop: some View {
        ZStack {
            if let backdropURL {
                AsyncImage(url: backdropURL) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFill()
                    } else {
                        CoverPlaceholder(gradient: CoverPalette.forTitle(result.title))
                    }
                }
            } else {
                CoverPlaceholder(gradient: CoverPalette.forTitle(result.title))
            }
        }
        .frame(height: 300)
        .overlay(LinearGradient(colors: [.clear, .dsPage],
                                startPoint: UnitPoint(x: 0.5, y: 0.4), endPoint: .bottom))
        .clipped()
        .task { backdropURL = await env.tmdb.backdropURL(title: result.title, year: nil) }
    }

    private var navBack: some View {
        Button { dismiss() } label: {
            GlassSurface(shape: .capsule, interactive: true) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.dsInk)
                    .frame(width: 40, height: 40)
            }
        }
        .padding(.leading, 16).padding(.top, 60)
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(result.title).font(.system(size: 26, weight: .heavy)).foregroundStyle(.dsInk)
            Text("\(result.items.count) 个片源命中")
                .font(.dsCaption).foregroundStyle(.dsInk2)
        }
        .padding(.horizontal, 20)
    }

    // MARK: 电影条目（点按 → 并发取全部电影源 → 多源对比播放）

    private var movieItems: [SourceItem] { result.items.filter { $0.type == .movie } }
    private var seriesItems: [SourceItem] { result.items.filter { $0.type == .series } }

    @ViewBuilder
    private var movieSection: some View {
        if !movieItems.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("电影").font(.dsSection).foregroundStyle(.dsInk)
                    .padding(.horizontal, 20).padding(.top, 20)
                ForEach(movieItems) { item in
                    sourceRow(item, subtitle: providerName(item)) {
                        Task { await playMovies() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var seriesSection: some View {
        if !seriesItems.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("剧集").font(.dsSection).foregroundStyle(.dsInk)
                    .padding(.horizontal, 20).padding(.top, 20)
                ForEach(seriesItems) { item in
                    sourceRow(item, subtitle: providerName(item)) {
                        Task { await toggleSeries(item) }
                    }
                    if expandedSeriesID == item.id, let eps = episodeCache[item.id], !eps.isEmpty {
                        episodeGrid(eps)
                            .padding(.horizontal, 20)
                    }
                }
            }
        }
    }

    private func providerName(_ item: SourceItem) -> String {
        env.providers.first { $0.id == item.providerId }?.displayName ?? item.providerId
    }

    private func sourceRow(_ item: SourceItem, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: item.type == .series ? "tv" : "film")
                    .font(.system(size: 15)).foregroundStyle(.dsInk2).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: 15, weight: .medium)).foregroundStyle(.dsInk)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text(subtitle).font(.dsCaption).foregroundStyle(.dsInk2)
                }
                Spacer()
                Image(systemName: item.type == .series ? "chevron.down" : "play.circle")
                    .font(.system(size: 14)).foregroundStyle(.dsInk3)
            }
            .padding(14)
            .background(GlassSurface(shape: .rounded(14)) { Color.clear })
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
    }

    private func episodeGrid(_ eps: [Episode]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 8)], spacing: 8) {
            ForEach(Array(eps.enumerated()), id: \.element.id) { idx, ep in
                Button { Task { await playEpisode(at: idx) } } label: {
                    VStack(spacing: 2) {
                        Text(ep.episode > 0 ? "第\(ep.episode)集" : "#\(idx + 1)")
                            .font(.system(size: 13, weight: .bold))
                        Text(ep.title).font(.system(size: 9)).foregroundStyle(.dsInk3).lineLimit(1)
                    }
                    .foregroundStyle(.dsInk)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(GlassSurface(shape: .rounded(10), interactive: true) { Color.clear })
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 播放动作

    private func toggleSeries(_ item: SourceItem) async {
        if expandedSeriesID == item.id {
            withAnimation(.dsEaseOut) { expandedSeriesID = nil }
            return
        }
        withAnimation(.dsEaseOut) { expandedSeriesID = item.id }
        if episodeCache[item.id] == nil {
            isFetching = true
            defer { isFetching = false }
            let provider = env.providers.first { $0.id == item.providerId }
            episodeCache[item.id] = (try? await provider?.episodes(of: item)) ?? []
        }
    }

    /// 电影：对全部电影源并发取流，质量分排序后交给播放器做来源对比
    private func playMovies() async {
        isFetching = true
        errorText = nil
        defer { isFetching = false }
        let options = await collectOptions(for: movieItems) { provider, item in
            let eps = try await provider.episodes(of: item)
            guard let ep = eps.first else { return nil }
            let info = try await provider.streamURL(of: ep)
            return (ep, info)
        }
        finishPlay(options: options, label: "正片", failText: "所有片源获取播放地址失败")
    }

    /// 剧集：按集序号在各服务器取对应集，多源对比播放
    private func playEpisode(at index: Int) async {
        isFetching = true
        errorText = nil
        defer { isFetching = false }
        let options = await collectOptions(for: seriesItems) { provider, item in
            if episodeCache[item.id] == nil {
                episodeCache[item.id] = (try? await provider.episodes(of: item)) ?? []
            }
            guard let eps = episodeCache[item.id], eps.indices.contains(index) else { return nil }
            let ep = eps[index]
            let info = try await provider.streamURL(of: ep)
            return (ep, info)
        }
        finishPlay(options: options, label: "第\(index + 1)集", failText: "获取第\(index + 1)集播放地址失败")
    }

    private func collectOptions(for items: [SourceItem],
                                fetch: @escaping (SourceProvider, SourceItem) async throws -> (Episode, StreamInfo)?
    ) async -> [StreamOption] {
        var options: [StreamOption] = []
        await withTaskGroup(of: StreamOption?.self) { group in
            for item in items {
                guard let provider = env.providers.first(where: { $0.id == item.providerId }) else { continue }
                let name = provider.displayName
                group.addTask {
                    do {
                        guard let (ep, info) = try await fetch(provider, item) else { return nil }
                        // refresh 闭包捕获 provider+episode：Alist 直链有时效，续播/换源前重取
                        return StreamOption(id: "\(item.id)|\(ep.id)", providerId: item.providerId,
                                            serverName: name, info: info,
                                            refresh: { try await provider.streamURL(of: ep) })
                    } catch {
                        return nil
                    }
                }
            }
            for await o in group { if let o { options.append(o) } }
        }
        return options.sorted { $0.info.qualityScore > $1.info.qualityScore }
    }

    private func finishPlay(options: [StreamOption], label: String, failText: String) {
        guard !options.isEmpty else {
            errorText = failText
            return
        }
        onPlay(PlayRequest(title: result.title, episodeLabel: label, options: options))
    }
}

// MARK: - 片源对比玻璃面板（播放器内换源：HDR/分辨率/码率/服务器 + 推荐标记）

struct SourceComparePanel: View {
    let options: [StreamOption]
    @Binding var selectedID: String?
    var onSelect: (StreamOption) -> Void = { _ in }
    var onClose: () -> Void

    private var bestScore: Int {
        options.map { $0.info.qualityScore }.max() ?? 0
    }

    var body: some View {
        GlassPanelSheet(title: "播放来源", icon: "square.stack.3d.up.fill", onClose: onClose) {
            // ScrollView：多片源时超出面板高度可滚动，不再被裁切
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("共 \(options.count) 个片源，切换后进度不变")
                        .font(.dsCaption).foregroundStyle(.dsInk2)
                        .padding(.horizontal, 20).padding(.top, 14)
                    ForEach(options) { option in
                        optionRow(option)
                    }
                    Color.clear.frame(height: 30)
                }
            }
        }
    }

    private func optionRow(_ option: StreamOption) -> some View {
        let isSelected = selectedID == option.id
        return Button {
            selectedID = option.id
            onSelect(option)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    tag(option.info.hdr)
                    tag(option.info.resolution)
                    if option.info.qualityScore == bestScore { tag("推荐", highlight: true) }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.dsInk3)
                }
                HStack(spacing: 12) {
                    Label(option.info.bitrateMbps > 0
                          ? String(format: "%.1f Mbps", option.info.bitrateMbps) : "码率未知",
                          systemImage: "gauge.high")
                    Label(option.info.recommendedEngine == .mpv ? "mpv" : "AVPlayer",
                          systemImage: "cpu")
                }
                .font(.system(size: 11.5)).foregroundStyle(.dsInk2)
                Text(option.serverName).font(.system(size: 14, weight: .semibold)).foregroundStyle(.dsInk)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.dsGlassBorder.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(isSelected ? Color.accentColor : Color.dsGlassBorder,
                                  lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
    }

    private func tag(_ t: String, highlight: Bool = false) -> some View {
        Text(t)
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(highlight ? Color.accentColor : .dsInk)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(highlight ? Color.accentColor.opacity(0.2) : Color.dsGlassBorder))
    }
}

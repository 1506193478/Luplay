import SwiftUI

/// 详情页（对标稿 v-detail）：hero 大图 + 居中楷体标题 + meta/chips + 播放胶囊 + ✓♡…
/// + 简介 + 选集（季/排序 pill + 可展开集面板）+ 演职人员 tabs + 剧照 + 相似推荐 + 媒体信息 + 链接来源
/// 播放链路保留：电影直接多源对比播放 / 剧集选集后多源对比播放
struct AggregateDetailView: View {
    let result: SearchAggregator.AggregatedResult
    var onPlay: (PlayRequest) -> Void

    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    // TMDB 元数据
    @State private var details: TMDBDetails?
    // 片源状态
    @State private var episodeCache: [String: [Episode]] = [:]   // itemId → 集列表
    @State private var expandedSeriesID: String?
    @State private var isFetching = false
    @State private var errorText: String?
    @State private var backdropURL: URL?
    // 选集控制
    @State private var seasonFilter: Int? = nil      // nil = 全部季
    @State private var newestFirst = true            // ⇄ 最新 / ↑ 正序
    @State private var epListMode = false            // ☰ 列表 / ▦ 网格
    // 交互状态
    @State private var loved = false
    @State private var watched = false
    @State private var castTab: Int = 0              // 0 演员 / 1 工作人员

    private var isSeries: Bool { result.items.contains { $0.type == .series } }
    private var seriesItems: [SourceItem] { result.items.filter { $0.type == .series } }
    private var movieItems: [SourceItem] { result.items.filter { $0.type == .movie } }
    private var firstYear: Int? { result.items.compactMap(\.year).first }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.dsPage.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    hero
                    bodyContent
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
        .overlay(alignment: .bottom) { toast }
        // 进媒体库（upsert）：打开过详情即收藏，记录归一化 key / 标题 / 命中片源 / 海报
        .task {
            loved = UserDefaults.standard.bool(forKey: "detail.loved.\(result.id)")
            watched = UserDefaults.standard.bool(forKey: "detail.watched.\(result.id)")
            details = await env.tmdb.details(title: result.title, year: firstYear)
            if backdropURL == nil {
                backdropURL = await env.tmdb.backdropURL(title: result.title, year: firstYear)
            }
            let ids = Array(Set(result.items.map(\.providerId))).sorted()
            let poster = await env.tmdb.posterURL(title: result.title, year: nil)
            try? env.database.save(libraryEntry: LibraryEntry(
                tmdbKey: result.id, title: result.title, providerIds: ids,
                posterPath: poster?.absoluteString, addedAt: Date()))
        }
    }

    // MARK: - Hero（470 高 + 底部渐隐 + 居中楷体标题 + tagline）

    private var hero: some View {
        ZStack {
            RemoteArt(url: backdropURL, title: result.title)
            LinearGradient(colors: [.clear, .dsPage],
                           startPoint: UnitPoint(x: 0.5, y: 0.55), endPoint: .bottom)
            VStack(spacing: 6) {
                if let tag = details?.tagline, !tag.isEmpty {
                    Text(tag)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color(red: 0.79, green: 0.21, blue: 0.17))
                        .tracking(6)
                        .lineLimit(1)
                }
                Text(result.title)
                    .font(.system(size: 36, weight: .black, design: .serif))
                    .tracking(4)
                    .foregroundStyle(Color(red: 0.96, green: 0.95, blue: 0.93))
                    .shadow(color: .black.opacity(0.65), radius: 12)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .offset(y: -26)
        }
        .frame(height: 470)
        .mask(LinearGradient(stops: [
            .init(color: .black, location: 0),
            .init(color: .black, location: 0.76),
            .init(color: .clear, location: 1.0),
        ], startPoint: .top, endPoint: .bottom))
    }

    private var navBack: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.dsInk)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.dsGlassFill))
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 16)
        .padding(.top, 58)
    }

    // MARK: - 正文（上移压住 hero 底部）

    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            metaLine
            chipsRow
            sourceSection
            actionRow
            overviewSection
            peopleSection
            stillsSection
            similarSection
            mediaInfoSection
            linksSection
        }
        .padding(.horizontal, 18)
        .padding(.top, -64)
    }

    private var metaLine: some View {
        HStack(spacing: 0) {
            if let y = firstYear { metaText("\(y)"); metaDot }
            metaText(isSeries ? "剧集" : "电影")
            if let r = details?.rating, r > 0 {
                metaDot
                metaText(String(format: "★ %.1f", r))
            }
            if let rt = details?.runtime, rt > 0 {
                metaDot
                metaText(isSeries ? "单集 \(rt) 分钟" : "\(rt) 分钟")
            }
            if let s = details?.seasons, isSeries, s > 0 {
                metaDot
                metaText("共 \(s) 季")
            }
        }
        .padding(.bottom, 10)
    }

    private func metaText(_ t: String) -> some View {
        Text(t).font(.system(size: 13)).foregroundStyle(.dsInk2)
    }
    private var metaDot: some View {
        Text("·").font(.system(size: 13)).foregroundStyle(.dsInk2).padding(.horizontal, 5)
    }

    // MARK: 类型 chips（评分 chip 金色，对标 chip-4k）

    private var chipsRow: some View {
        FlowChips(items: chips)
            .padding(.bottom, 16)
    }

    private var chips: [DetailChip] {
        var arr: [DetailChip] = []
        if let r = details?.rating, r > 0 {
            arr.append(DetailChip(text: String(format: "★ %.1f", r), gold: true))
        }
        for g in (details?.genres ?? []).prefix(4) {
            arr.append(DetailChip(text: g, gold: false))
        }
        return arr
    }

    // MARK: 片源卡片（玻璃卡：电影点按播放 / 剧集点按展开选集）

    @ViewBuilder
    private var sourceSection: some View {
        if !result.items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("片源").detailSectionTitle()
                ForEach(movieItems) { item in
                    sourceCard(item: item,
                               icon: "film",
                               subtitle: "电影 · \(providerName(item))",
                               trailing: "play.fill") {
                        Task { await playMovies() }
                    }
                }
                ForEach(seriesItems) { item in
                    sourceCard(item: item,
                               icon: "tv",
                               subtitle: "剧集 · \(providerName(item)) · \(episodeCount(item))",
                               trailing: expandedSeriesID == item.id ? "chevron.up" : "chevron.down") {
                        Task { await toggleSeries(item) }
                    }
                    if expandedSeriesID == item.id {
                        episodePanel(for: item)
                            .padding(.bottom, 4)
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func episodeCount(_ item: SourceItem) -> String {
        if let eps = episodeCache[item.id], !eps.isEmpty { return "共 \(eps.count) 集" }
        return "点按加载选集"
    }

    private func sourceCard(item: SourceItem, icon: String, subtitle: String,
                            trailing: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(.dsInk2)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.dsGlassFill))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundStyle(.dsInk)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.dsInk2)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: trailing)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.dsInk)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(.dsGlassFill))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 18).fill(.dsGlassFill))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.dsGlassBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: 播放动作（playpill + ✓/♡/…）

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                if isSeries { Task { await playEpisode(at: 0) } } else { Task { await playMovies() } }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "play.fill").font(.system(size: 14))
                    Text(playLabel)
                        .font(.system(size: 16.5, weight: .heavy))
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                .foregroundStyle(Color.black)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Capsule().fill(Color(red: 0.97, green: 0.96, blue: 0.93)))
            }
            .buttonStyle(.plain)

            actionCircle(icon: "checkmark",
                         active: watched, activeTint: .dsAccent) {
                watched.toggle()
                UserDefaults.standard.set(watched, forKey: "detail.watched.\(result.id)")
            }
            actionCircle(icon: loved ? "heart.fill" : "heart",
                         active: loved, activeTint: Color(red: 1, green: 0.35, blue: 0.35)) {
                loved.toggle()
                UserDefaults.standard.set(loved, forKey: "detail.loved.\(result.id)")
            }
            Menu {
                Button {} label: { Label("投屏", systemImage: "airplayvideo") }
                    .disabled(true)
                Button {} label: { Label("仅一个版本", systemImage: "rectangle.on.rectangle") }
                    .disabled(true)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.dsInk)
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(.dsGlassFill))
            }
        }
        .padding(.bottom, 22)
    }

    private var playLabel: String {
        isSeries ? "播放第 1 集" : "立即播放"
    }

    private func actionCircle(icon: String, active: Bool, activeTint: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(active ? activeTint : .dsInk)
                .frame(width: 54, height: 54)
                .background(Circle().fill(active
                    ? AnyShapeStyle(activeTint.opacity(0.18))
                    : AnyShapeStyle(.dsGlassFill)))
        }
        .buttonStyle(.plain)
    }

    // MARK: 简介

    @ViewBuilder
    private var overviewSection: some View {
        if let ov = details?.overview, !ov.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("简介").detailSectionTitle()
                Text(ov)
                    .font(.system(size: 14))
                    .lineSpacing(6)
                    .foregroundStyle(.dsInk2)
            }
        }
    }

    // MARK: 选集（季 pill + 排序 pill + 列表/网格切换，多片源各占一张卡）

    @ViewBuilder
    private func episodePanel(for item: SourceItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            pillRow
            if epListMode {
                episodeList(for: item)
            } else {
                episodeGrid(for: item)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18).fill(.dsGlassFill))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.dsGlassBorder, lineWidth: 1))
    }

    private var pillRow: some View {
        HStack(spacing: 8) {
            if displayEpisodes(placeholder: false).count > 0, seasonPillVisible {
                Menu {
                    ForEach(availableSeasons, id: \.self) { s in
                        Button("第 \(s) 季") { seasonFilter = s }
                    }
                    Button("全部季") { seasonFilter = nil }
                } label: {
                    pillText(seasonFilter.map { "第 \($0) 季 ⌄" } ?? "全部季 ⌄")
                }
            }
            Button {
                withAnimation(.dsSpring) { newestFirst.toggle() }
            } label: {
                pillText(newestFirst ? "⇄ 最新" : "↑ 正序")
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                withAnimation(.dsSpring) { epListMode.toggle() }
            } label: {
                pillText(epListMode ? "☰" : "▦")
            }
            .buttonStyle(.plain)
        }
    }

    private var seasonPillVisible: Bool { availableSeasons.count > 1 }

    private var availableSeasons: [Int] {
        Array(Set(seriesItems.compactMap { episodeCache[$0.id] }.flatMap { $0.map(\.season) })).sorted()
    }

    private func pillText(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.dsInk)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(.dsGlassFill))
    }

    /// 当前筛选+排序后的集列表（占位参数用于在无缓存时也参与 pill 显隐判断）
    private func displayEpisodes(placeholder: Bool) -> [Episode] {
        guard let first = seriesItems.first, let eps = episodeCache[first.id], !eps.isEmpty else { return [] }
        var list = eps
        if let s = seasonFilter { list = list.filter { $0.season == s } }
        if newestFirst { list = list.sorted { ($0.season, $0.episode) > ($1.season, $1.episode) } }
        return list
    }

    private func episodes(of item: SourceItem) -> [Episode] {
        var list = episodeCache[item.id] ?? []
        if let s = seasonFilter { list = list.filter { $0.season == s } }
        if newestFirst { list = list.sorted { ($0.season, $0.episode) > ($1.season, $1.episode) } }
        return list
    }

    private func episodeGrid(for item: SourceItem) -> some View {
        let eps = episodes(of: item)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 8)], spacing: 8) {
            ForEach(Array(eps.enumerated()), id: \.element.id) { idx, ep in
                Button {
                    Task { await playEpisode(from: item, episode: ep) }
                } label: {
                    VStack(spacing: 2) {
                        Text(ep.episode > 0 ? "第\(ep.episode)集" : "#\(idx + 1)")
                            .font(.system(size: 13, weight: .heavy))
                        Text(ep.title).font(.system(size: 9)).foregroundStyle(.dsInk3).lineLimit(1)
                    }
                    .foregroundStyle(.dsInk)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.dsGlassFill))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func episodeList(for item: SourceItem) -> some View {
        let eps = episodes(of: item)
        return VStack(spacing: 0) {
            ForEach(Array(eps.enumerated()), id: \.element.id) { _, ep in
                Button {
                    Task { await playEpisode(from: item, episode: ep) }
                } label: {
                    HStack(spacing: 12) {
                        Text(ep.episode > 0 ? "\(ep.episode)" : "•")
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(.dsInk2)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(.dsGlassFill))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ep.title.isEmpty ? "第 \(max(ep.episode, 1)) 集" : ep.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.dsInk)
                                .lineLimit(1)
                            if ep.season > 0 {
                                Text("第 \(ep.season) 季")
                                    .font(.system(size: 11)).foregroundStyle(.dsInk3)
                            }
                        }
                        Spacer()
                        Image(systemName: "play.circle")
                            .font(.system(size: 15)).foregroundStyle(.dsInk3)
                    }
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 演职人员（演员/工作人员 tabs + 圆头像横滚）

    @ViewBuilder
    private var peopleSection: some View {
        if let d = details, !d.cast.isEmpty || !d.crew.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("演职人员").detailSectionTitle()
                HStack(spacing: 8) {
                    peopleTab("演员", index: 0)
                    peopleTab("工作人员", index: 1)
                }
                .padding(.bottom, 4)
                if castTab == 0 {
                    castRow(d.cast)
                } else {
                    crewList(d.crew)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func peopleTab(_ label: String, index: Int) -> some View {
        Button {
            withAnimation(.dsSpring) { castTab = index }
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(castTab == index ? Color.white : Color.dsInk2)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Capsule().fill(castTab == index
                    ? AnyShapeStyle(.white.opacity(0.25))
                    : AnyShapeStyle(.dsGlassFill)))
        }
        .buttonStyle(.plain)
    }

    private func castRow(_ cast: [TMDBPerson]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(cast) { p in
                    VStack(spacing: 7) {
                        RemoteArt(url: p.profileURL, title: p.name)
                            .frame(width: 64, height: 64)
                            .clipShape(Circle())
                        Text(p.name)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.dsInk)
                            .lineLimit(1)
                        Text(p.role)
                            .font(.system(size: 10))
                            .foregroundStyle(.dsInk2)
                            .lineLimit(1)
                    }
                    .frame(width: 64)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func crewList(_ crew: [TMDBPerson]) -> some View {
        VStack(spacing: 0) {
            ForEach(crew.prefix(12)) { p in
                HStack {
                    Text(p.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.dsInk)
                    Spacer()
                    Text(p.role).font(.system(size: 12)).foregroundStyle(.dsInk2)
                }
                .padding(.vertical, 9)
                if p.id != crew.prefix(12).last?.id {
                    Rectangle().fill(.dsGlassBorder).frame(height: 0.5)
                }
            }
        }
    }

    // MARK: 剧照（78% 宽 16:9 横滚）

    @ViewBuilder
    private var stillsSection: some View {
        if let stills = details?.stills, !stills.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("剧照").detailSectionTitle()
                    Spacer()
                    Text("\(stills.count)").font(.system(size: 12)).foregroundStyle(.dsInk3)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(stills, id: \.absoluteString) { url in
                            RemoteArt(url: url, title: result.title)
                                .frame(width: stillWidth, height: stillWidth * 9 / 16)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private var stillWidth: CGFloat { UIScreen.main.bounds.width * 0.74 }

    // MARK: 相似推荐（118×168 竖版海报横滚）

    @ViewBuilder
    private var similarSection: some View {
        if let sim = details?.similar, !sim.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("相似推荐").detailSectionTitle()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(sim) { s in
                            VStack(alignment: .leading, spacing: 7) {
                                RemoteArt(url: s.posterURL, title: s.title)
                                    .frame(width: 118, height: 168)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                                    .overlay(alignment: .bottom) {
                                        Text(s.title)
                                            .font(.system(size: 12, weight: .heavy))
                                            .foregroundStyle(.white)
                                            .shadow(color: .black.opacity(0.6), radius: 4)
                                            .lineLimit(1)
                                            .padding(8)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                Text(s.title)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(.dsInk)
                                    .lineLimit(1)
                                if let y = s.year {
                                    Text("\(y)").font(.system(size: 11)).foregroundStyle(.dsInk2)
                                }
                            }
                            .frame(width: 118)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
            .padding(.bottom, 8)
        }
    }

    // MARK: 媒体信息（分区行卡）

    @ViewBuilder
    private var mediaInfoSection: some View {
        let rows: [(String, String)] = mediaInfoRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("媒体信息").detailSectionTitle()
                VStack(spacing: 0) {
                    ForEach(rows, id: \.0) { row in
                        HStack(alignment: .top) {
                            Text(row.0)
                                .font(.system(size: 12))
                                .foregroundStyle(.dsInk3)
                                .frame(width: 56, alignment: .leading)
                            Text(row.1)
                                .font(.system(size: 12))
                                .foregroundStyle(.dsInk.opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        if row.0 != rows.last?.0 {
                            Rectangle().fill(.dsGlassBorder).frame(height: 0.5)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(.dsGlassFill))
            }
            .padding(.bottom, 8)
        }
    }

    private var mediaInfoRows: [(String, String)] {
        guard let d = details else { return [] }
        var rows: [(String, String)] = []
        rows.append(("类型", isSeries ? "剧集" : "电影"))
        if let y = firstYear { rows.append(("年份", "\(y)")) }
        if let s = d.seasons, isSeries { rows.append(("季数", "\(s) 季")) }
        if let rt = d.runtime, rt > 0 {
            rows.append(("时长", isSeries ? "单集 \(rt) 分钟" : "\(rt) 分钟"))
        }
        if !d.genres.isEmpty { rows.append(("分类", d.genres.joined(separator: " / "))) }
        if let r = d.rating, r > 0 { rows.append(("评分", String(format: "%.1f / 10", r))) }
        return rows
    }

    // MARK: 链接来源（TMDB 蓝色胶囊，点击打开网页）

    @ViewBuilder
    private var linksSection: some View {
        if let d = details {
            HStack(spacing: 10) {
                Button {
                    if let url = URL(string: "https://www.themoviedb.org/\(d.mediaType)/\(d.tmdbID)") {
                        openURL(url)
                    }
                } label: {
                    Label("TheMovieDb", systemImage: "link")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color(red: 0.62, green: 0.72, blue: 1))
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .background(Capsule().fill(Color(red: 0.43, green: 0.55, blue: 1).opacity(0.13)))
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 10)
        }
    }

    // MARK: - 交互与播放（逻辑保留）

    private var toast: some View {
        Group {
            if let errorText {
                toastCapsule(text: errorText, icon: "exclamationmark.triangle.fill")
            }
        }
    }

    private func toastCapsule(text: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.dsInk)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(GlassSurface(shape: .capsule) { Color.clear })
        .padding(.bottom, 40)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func providerName(_ item: SourceItem) -> String {
        env.providers.first { $0.id == item.providerId }?.displayName ?? item.providerId
    }

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
            return (ep, [], info)   // 电影无剧集通道
        }
        finishPlay(options: options, label: "正片", failText: "所有片源获取播放地址失败")
    }

    /// 从指定片源的指定集播放（选集网格/列表入口）
    private func playEpisode(from item: SourceItem, episode: Episode) async {
        isFetching = true
        errorText = nil
        defer { isFetching = false }
        let options = await collectOptions(for: seriesItems) { provider, it in
            if episodeCache[it.id] == nil {
                episodeCache[it.id] = (try? await provider.episodes(of: it)) ?? []
            }
            guard let eps = episodeCache[it.id] else { return nil }
            // 按季+集号匹配其他服务器的对应集
            guard let ep = eps.first(where: { $0.season == episode.season && $0.episode == episode.episode })
                    ?? eps.first(where: { $0.episode == episode.episode }) else { return nil }
            let info = try await provider.streamURL(of: ep)
            return (ep, eps, info)
        }
        // 全集标签以首个有集列表的剧集源为准（各源集数一般一致）
        let index = episodeIndex(of: episode)
        let titles = seriesItems.lazy.compactMap { episodeCache[$0.id] }.first.map { eps in
            eps.enumerated().map { idx, ep in ep.episode > 0 ? "第\(ep.episode)集" : "#\(idx + 1)" }
        } ?? []
        finishPlay(options: options, label: episode.episode > 0 ? "第\(episode.episode)集" : episode.title,
                   failText: "获取播放地址失败",
                   episodes: titles, currentIndex: index)
    }

    private func episodeIndex(of episode: Episode) -> Int {
        let all = seriesItems.compactMap { episodeCache[$0.id] }.first ?? []
        return all.firstIndex(where: { $0.id == episode.id }) ?? 0
    }

    /// 兼容入口：按集序号播放
    private func playEpisode(at index: Int) async {
        guard let item = seriesItems.first else { return }
        if episodeCache[item.id] == nil {
            isFetching = true
            let provider = env.providers.first { $0.id == item.providerId }
            episodeCache[item.id] = (try? await provider?.episodes(of: item)) ?? []
            isFetching = false
        }
        guard let eps = episodeCache[item.id], eps.indices.contains(index) else {
            errorText = "暂无可用剧集"
            return
        }
        await playEpisode(from: item, episode: eps[index])
    }

    private func collectOptions(for items: [SourceItem],
                                fetch: @escaping (SourceProvider, SourceItem) async throws -> (Episode, [Episode], StreamInfo)?
    ) async -> [StreamOption] {
        var options: [StreamOption] = []
        await withTaskGroup(of: StreamOption?.self) { group in
            for item in items {
                guard let provider = env.providers.first(where: { $0.id == item.providerId }) else { continue }
                let name = provider.displayName
                group.addTask {
                    do {
                        guard let (ep, eps, info) = try await fetch(provider, item) else { return nil }
                        // refresh 闭包捕获 provider+episode：Alist 直链有时效，续播/换源前重取
                        // episodeStream：剧集切换通道（按集序号取该源对应集的流）
                        return StreamOption(
                            id: "\(item.id)|\(ep.id)", providerId: item.providerId,
                            serverName: name, info: info,
                            refresh: { try await provider.streamURL(of: ep) },
                            episodeStream: eps.isEmpty ? nil : { idx in
                                guard eps.indices.contains(idx) else { throw ProviderError.notImplemented }
                                return try await provider.streamURL(of: eps[idx])
                            })
                    } catch {
                        return nil
                    }
                }
            }
            for await o in group { if let o { options.append(o) } }
        }
        return options.sorted { $0.info.qualityScore > $1.info.qualityScore }
    }

    private func finishPlay(options: [StreamOption], label: String, failText: String,
                            episodes: [String]? = nil, currentIndex: Int = 0) {
        guard !options.isEmpty else {
            withAnimation(.dsEaseOut) { errorText = failText }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation(.dsEaseOut) { errorText = nil }
            }
            return
        }
        onPlay(PlayRequest(title: result.title, episodeLabel: label, options: options,
                           episodeTitles: (episodes?.isEmpty == false) ? episodes : nil,
                           currentEpisodeIndex: currentIndex))
    }
}

// MARK: - 详情页小组件

/// 类型 chips（评分金色 chip + 白玻璃 genre chip，对标 chip-d / chip-4k）
struct DetailChip: Identifiable {
    let text: String
    let gold: Bool
    var id: String { text }
}

struct FlowChips: View {
    let items: [DetailChip]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), alignment: .leading)], alignment: .leading, spacing: 7) {
            ForEach(items) { chip in
                Text(chip.text)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(chip.gold ? Color(red: 0.13, green: 0.08, blue: 0.02) : .dsInk)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8).fill(chip.gold
                        ? AnyShapeStyle(LinearGradient(colors: [Color(red: 0.96, green: 0.84, blue: 0.56),
                                                                    Color(red: 0.85, green: 0.66, blue: 0.31)],
                                                                       startPoint: .topLeading, endPoint: .bottomTrailing))
                        : AnyShapeStyle(.dsGlassFill)))
            }
        }
    }
}

/// 分区标题（18 加粗，v-detail .dsec）
extension View {
    func detailSectionTitle() -> some View {
        font(.system(size: 18, weight: .heavy))
            .foregroundStyle(.dsInk)
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

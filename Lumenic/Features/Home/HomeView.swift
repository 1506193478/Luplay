import SwiftUI

/// 首页（对标 lumenic-home.html）：问候语顶栏 + 真实 hero 轮播 + 继续/历史 + 我的媒体库
/// 数据全部来自已配置片源（Emby /Items/Latest、文件源浅层扫描）+ 本地进度库 + TMDB 海报补全
struct HomeView: View {
    var openPlayer: (PlayRequest) -> Void = { _ in }
    var openSearch: () -> Void = {}
    var openSettings: () -> Void = {}
    @EnvironmentObject private var env: AppEnvironment

    enum ContinueTab: String { case cont = "继续", hist = "历史" }

    @State private var heroIndex = 0
    @State private var latestItems: [SourceItem] = []     // 各源最新入库
    @State private var libraries: [SourceLibrary] = []    // 各源媒体库
    @State private var posters: [String: URL] = [:]       // item.id → TMDB 竖版海报
    @State private var backdrops: [String: URL] = [:]     // item.id → TMDB 横版背景
    @State private var progressEntries: [PlaybackProgress] = []
    @State private var contTab: ContinueTab = .cont
    @State private var loading = true
    @State private var resolving: String? = nil           // 正在解析片源的标题（toast）
    @State private var statusText: String? = nil          // 解析结果提示

    var body: some View {
        ZStack(alignment: .top) {
            heroBackground

            ScrollView(showsIndicators: false) {
                hero
                continueSection
                librarySection
                Color.clear.frame(height: 120)
            }
            .ignoresSafeArea(edges: .top)
        }
        .overlay(alignment: .top) { topBar }
        .overlay(alignment: .bottom) { toast }
        .overlay(alignment: .bottomTrailing) { fab }
        .task(id: env.providers.count) { await loadHome() }
    }

    // MARK: 顶栏（问候语 + 服务器胶囊菜单）
    private var topBar: some View {
        HStack(alignment: .bottom) {
            Text(greeting)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.dsInk)
                .shadow(color: .black.opacity(0.5), radius: 10)
            Spacer()
            serverPill
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private var serverPill: some View {
        Menu {
            ForEach(env.providers.filter { $0.isConfigured }, id: \.id) { p in
                Button {} label: { Label(p.displayName, systemImage: "server.rack") }
            }
            if env.providers.filter({ $0.isConfigured }).isEmpty {
                Button {} label: { Label("未配置片源", systemImage: "exclamationmark.triangle") }
            }
            Divider()
            Button { openSearch() } label: { Label("搜索", systemImage: "magnifyingglass") }
            Button { openSettings() } label: { Label("管理片源…", systemImage: "slider.horizontal.3") }
        } label: {
            GlassSurface(shape: .capsule, interactive: true) {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(colors: [.green, .green.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 20, height: 20)
                        .overlay(Text("▶").font(.system(size: 10, weight: .bold)).foregroundStyle(.white))
                    Text(serverPillTitle)
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(.dsInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.dsInk2)
                }
            }
            .frame(maxWidth: 230, minHeight: 40)
        }
    }

    private var serverPillTitle: String {
        let configured = env.providers.filter { $0.isConfigured }
        if configured.isEmpty { return "未配置片源" }
        return configured.count > 1 ? configured[0].displayName : configured[0].displayName
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 0..<5: return "夜深了"
        case 5..<11: return "早上好"
        case 11..<13: return "中午好"
        case 13..<18: return "下午好"
        default: return "晚上好"
        }
    }

    // MARK: 整页背景 = 当前 hero 封面模糊放大
    private var heroBackground: some View {
        ZStack {
            if heroItems.indices.contains(heroIndex) {
                RemoteArt(url: backdrop(of: heroItems[heroIndex]), title: heroItems[heroIndex].title)
            } else {
                CoverPlaceholder(gradient: MockStore.hero[0].gradient)
            }
        }
        .blur(radius: 44)
        .scaleEffect(1.25)
        .ignoresSafeArea()
        .overlay(Color.dsPage.opacity(0.35).ignoresSafeArea())
        .animation(.easeInOut(duration: 0.9), value: heroIndex)
        .id(heroIndex)
        .transition(.opacity)
    }

    private var heroItems: [SourceItem] { Array(latestItems.prefix(8)) }

    // MARK: Hero 轮播（真实最新入库；无内容时引导添加片源）
    private var hero: some View {
        VStack(spacing: 8) {
            if latestItems.isEmpty {
                heroPlaceholder
                    .frame(height: 400)
            } else {
                TabView(selection: $heroIndex) {
                    ForEach(Array(heroItems.enumerated()), id: \.1.id) { i, item in
                        heroSlide(item).tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 400)

                HStack(spacing: 5) {
                    ForEach(0..<heroItems.count, id: \.self) { i in
                        Capsule()
                            .fill(heroIndex == i ? Color.white : .white.opacity(0.38))
                            .frame(width: heroIndex == i ? 17 : 5, height: 5)
                            .animation(.dsSpring, value: heroIndex)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
            }
        }
        .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .init(x: 0.5, y: 0), endPoint: .init(x: 0.5, y: 0.96)))
    }

    private func heroSlide(_ item: SourceItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            RemoteArt(url: backdrop(of: item), title: item.title)
            LinearGradient(colors: [.clear, .dsPage.opacity(0.9)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 12)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(heroMeta(item))
                    .font(.dsCaption)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }
            .padding(22)
        }
        .contentShape(Rectangle())
        .onTapGesture { Task { await resolvePlay(item: item) } }
    }

    private func heroMeta(_ item: SourceItem) -> String {
        var parts: [String] = []
        if let y = item.year { parts.append("\(y)") }
        parts.append(item.type == .series ? "剧集" : "电影")
        return parts.joined(separator: " · ")
    }

    private var heroPlaceholder: some View {
        ZStack {
            CoverPlaceholder(gradient: MockStore.hero[0].gradient)
            VStack(spacing: 12) {
                if loading {
                    ProgressView().tint(.white)
                } else {
                    Text("还没有媒体内容")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                    Text("添加 Emby / Alist / WebDAV 后即可浏览媒体库")
                        .font(.dsCaption)
                        .foregroundStyle(.white.opacity(0.6))
                    Button { openSettings() } label: {
                        Text("添加片源")
                            .font(.system(size: 14, weight: .bold))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(Color.dsAccent))
                            .foregroundStyle(.white)
                    }
                }
            }
        }
    }

    // MARK: 继续 / 历史（真实进度库）
    private var continueSection: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 14) {
                    tabButton("继续", tab: .cont)
                    tabButton("历史", tab: .hist)
                }
                Spacer()
                if !continueEntries.isEmpty {
                    HStack(spacing: 2) {
                        Text("\(continueEntries.count)")
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
                HStack(spacing: 11) {
                    if continueEntries.isEmpty {
                        Text(contTab == .cont ? "暂无观看记录" : "历史记录为空")
                            .font(.dsCaption)
                            .foregroundStyle(.dsInk2)
                            .padding(.vertical, 34)
                    } else {
                        ForEach(continueEntries, id: \.tmdbKey) { entry in
                            resumeRow(entry)
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func tabButton(_ label: String, tab: ContinueTab) -> some View {
        Button {
            withAnimation(.dsSpring) { contTab = tab }
        } label: {
            Text(label)
                .font(.system(size: 19, weight: contTab == tab ? .heavy : .medium))
                .foregroundStyle(contTab == tab ? .dsInk : .dsInk2)
        }
        .buttonStyle(.plain)
    }

    private var continueEntries: [PlaybackProgress] {
        switch contTab {
        case .cont: return progressEntries.filter { fraction($0) < 0.95 }
        case .hist: return progressEntries
        }
    }

    private func fraction(_ e: PlaybackProgress) -> Double {
        e.duration > 0 ? min(1, e.position / e.duration) : 0
    }

    /// 进度条目卡片：真实封面（TMDB 海报）+ 剩余时间 + 进度条；点击从任意已配置源续播
    private func resumeRow(_ entry: PlaybackProgress) -> some View {
        let parts = entry.tmdbKey.split(separator: "|", maxSplits: 1).map(String.init)
        let title = parts.first ?? entry.tmdbKey
        let episodeLabel = parts.count > 1 ? parts[1] : "正片"
        let f = fraction(entry)
        let remaining = max(0, entry.duration - entry.position)
        return VStack(alignment: .leading, spacing: 7) {
            RemoteArt(url: posters[entry.tmdbKey], title: title)
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
                                Capsule().fill(Color.dsAccent).frame(width: geo.size.width * f)
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
        .onTapGesture { Task { await resumePlay(entry: entry) } }
    }

    private static func timeText(_ t: Double) -> String {
        let total = Int(t), m = total / 60, s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: 我的媒体（真实媒体库：Emby Views / 文件源根目录）
    private var librarySection: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("我的媒体").font(.dsSection).foregroundStyle(.dsInk)
                Spacer()
                if !libraries.isEmpty {
                    HStack(spacing: 2) {
                        Text("\(libraries.count)")
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
                HStack(spacing: 11) {
                    if libraries.isEmpty {
                        libraryAddCard
                    } else {
                        ForEach(libraries) { lib in
                            libraryRow(lib)
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func libraryRow(_ lib: SourceLibrary) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            CoverPlaceholder(gradient: CoverPalette.forTitle(lib.name))
                .frame(width: 148, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .overlay(alignment: .bottomLeading) {
                    Text(lib.name).font(.system(size: 14, weight: .heavy)).foregroundStyle(.white).padding(11)
                }
            Text(providerName(for: lib)).font(.dsCaption).foregroundStyle(.dsInk2)
                .lineLimit(1)
                .frame(maxWidth: 148, alignment: .leading)
        }
    }

    private var libraryAddCard: some View {
        Button { openSettings() } label: {
            VStack(alignment: .leading, spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13)
                        .fill(Color.dsCard)
                        .frame(width: 148, height: 84)
                    VStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.dsAccent)
                        Text("添加媒体服务器")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.dsInk2)
                    }
                }
                Text("Emby / Alist / WebDAV")
                    .font(.dsCaption).foregroundStyle(.dsInk2)
            }
        }
        .buttonStyle(.plain)
    }

    private func providerName(for lib: SourceLibrary) -> String {
        let pid = lib.id.split(separator: "|", maxSplits: 1).first.map(String.init) ?? ""
        return env.providers.first { $0.id == pid }?.displayName ?? "片源"
    }

    // MARK: Toast（解析中 / 结果提示）
    @ViewBuilder
    private var toast: some View {
        VStack(spacing: 8) {
            if let resolving {
                toastCapsule {
                    ProgressView().tint(.dsInk)
                    Text("正在解析「\(resolving)」的片源…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.dsInk)
                }
            }
            if let statusText {
                toastCapsule {
                    Text(statusText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.dsInk)
                        .lineLimit(2)
                }
            }
        }
        .padding(.bottom, 108)
        .animation(.dsEaseOut, value: resolving)
        .animation(.dsEaseOut, value: statusText)
    }

    private func toastCapsule<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(content)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Capsule().fill(.ultraThinMaterial))
            .padding(.horizontal, 24)
    }

    // MARK: 搜索 FAB
    private var fab: some View {
        Button { openSearch() } label: {
            GlassSurface(shape: .capsule, interactive: true) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.dsInk)
                    .frame(width: 54, height: 54)
            }
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
        .padding(.trailing, 18)
        .padding(.bottom, 96)
    }

    // MARK: 数据加载

    private func loadHome() async {
        loading = true
        // 各源并发：最新入库 + 媒体库
        var items: [SourceItem] = []
        var libs: [SourceLibrary] = []
        await withTaskGroup(of: ([SourceItem], [SourceLibrary]).self) { group in
            for p in env.providers where p.isConfigured {
                group.addTask {
                    let i = (try? await p.latest(limit: 12)) ?? []
                    let l = (try? await p.libraries()) ?? []
                    return (i, l)
                }
            }
            for await (i, l) in group {
                items += i
                libs += l
            }
        }
        latestItems = items
        libraries = libs
        heroIndex = 0
        progressEntries = (try? env.database.allProgress()) ?? []
        loading = false
        await fillPosters()
    }

    /// TMDB 海报补全：源未自带（文件型源）的条目按标题刮削
    private func fillPosters() async {
        for item in latestItems {
            if item.posterURL == nil, posters[item.id] == nil {
                posters[item.id] = await env.tmdb.posterURL(title: item.title, year: item.year)
            }
            if item.backdropURL == nil, backdrops[item.id] == nil {
                backdrops[item.id] = await env.tmdb.backdropURL(title: item.title, year: item.year)
            }
        }
        // 继续观看条目也按标题补 TMDB 海报
        for entry in progressEntries {
            let title = entry.tmdbKey.split(separator: "|", maxSplits: 1).first.map(String.init) ?? entry.tmdbKey
            if posters[entry.tmdbKey] == nil {
                posters[entry.tmdbKey] = await env.tmdb.posterURL(title: title, year: nil)
            }
        }
    }

    private func poster(of item: SourceItem) -> URL? { item.posterURL ?? posters[item.id] }
    private func backdrop(of item: SourceItem) -> URL? { item.backdropURL ?? backdrops[item.id] ?? poster(of: item) }

    // MARK: 真实播放链路

    /// 点击 hero 条目：聚合同名条目 → 构建播放请求 → 拉起播放器
    private func resolvePlay(item: SourceItem) async {
        guard resolving == nil else { return }
        resolving = item.title
        defer { resolving = nil }
        var items: [SourceItem] = [item]
        await withTaskGroup(of: [SourceItem].self) { group in
            for p in env.providers where p.isConfigured && p.id != item.providerId {
                group.addTask { (try? await p.search(item.title)) ?? [] }
            }
            for await r in group {
                items += r.filter { $0.title == item.title && $0.id != item.id }
            }
        }
        if let req = await buildRequest(items: items, title: item.title, resume: nil) {
            openPlayer(req)
        } else {
            await flashStatus("未能从任何片源获取「\(item.title)」的播放地址")
        }
    }

    /// 点击继续观看：按媒体 key 跨源检索 → 定位续播集 → 播放器自动恢复进度
    private func resumePlay(entry: PlaybackProgress) async {
        guard resolving == nil else { return }
        let parts = entry.tmdbKey.split(separator: "|", maxSplits: 1).map(String.init)
        let title = parts.first ?? entry.tmdbKey
        resolving = title
        defer { resolving = nil }
        var items: [SourceItem] = []
        await withTaskGroup(of: [SourceItem].self) { group in
            for p in env.providers where p.isConfigured {
                group.addTask { (try? await p.search(title)) ?? [] }
            }
            for await r in group {
                items += r.filter { $0.title == title }
            }
        }
        if let req = await buildRequest(items: items, title: title, resume: entry) {
            openPlayer(req)
        } else {
            await flashStatus("未找到「\(title)」的片源，请检查媒体服务器")
        }
    }

    /// 多源构建播放请求：取各源集列表 → 按续播定位起始集 → 并发取流 → qualityScore 排序
    private func buildRequest(items: [SourceItem], title: String,
                              resume: PlaybackProgress?) async -> PlayRequest? {
        // 1) 各源集列表
        var epsByItem: [String: [Episode]] = [:]
        await withTaskGroup(of: (String, [Episode])?.self) { group in
            for it in items {
                guard let p = env.providers.first(where: { $0.id == it.providerId }) else { continue }
                group.addTask {
                    guard let eps = try? await p.episodes(of: it), !eps.isEmpty else { return nil }
                    return (it.id, eps)
                }
            }
            for await r in group { if let (id, eps) = r { epsByItem[id] = eps } }
        }

        // 2) 全集标签（首个有集列表的剧集源）
        let allTitles = epsByItem.values.first { $0.count > 1 }.map { eps in
            eps.enumerated().map { idx, ep in ep.episode > 0 ? "第\(ep.episode)集" : "#\(idx + 1)" }
        }

        // 3) 并发取流
        var pairs: [(option: StreamOption, index: Int)] = []
        await withTaskGroup(of: (StreamOption, Int)?.self) { group in
            for it in items {
                guard let p = env.providers.first(where: { $0.id == it.providerId }),
                      let eps = epsByItem[it.id], !eps.isEmpty else { continue }
                // 定位起始集：续播按 season/episode 匹配，否则取第一集
                var idx = 0
                if let resume {
                    if let hit = eps.firstIndex(where: { $0.season == resume.season && $0.episode == resume.episode }) {
                        idx = hit
                    } else if let hit = eps.firstIndex(where: { $0.episode == resume.episode }) {
                        idx = hit
                    }
                }
                let ep = eps[idx]
                let startIndex = idx
                group.addTask {
                    do {
                        let info = try await p.streamURL(of: ep)
                        let option = StreamOption(
                            id: "\(it.id)|\(ep.id)", providerId: it.providerId,
                            serverName: p.displayName, info: info,
                            refresh: { try await p.streamURL(of: ep) },
                            episodeStream: eps.count > 1 ? { i in
                                guard eps.indices.contains(i) else { throw ProviderError.notImplemented }
                                return try await p.streamURL(of: eps[i])
                            } : nil)
                        return (option, startIndex)
                    } catch {
                        return nil
                    }
                }
            }
            for await r in group { if let (o, i) = r { pairs.append((o, i)) } }
        }

        guard let best = pairs.max(by: { $0.option.info.qualityScore < $1.option.info.qualityScore }) else { return nil }

        let label: String
        if let resume {
            let parts = resume.tmdbKey.split(separator: "|", maxSplits: 1).map(String.init)
            label = parts.count > 1 ? parts[1] : "正片"
        } else {
            label = allTitles == nil ? "正片" : "第\(best.index + 1)集"
        }
        return PlayRequest(title: title, episodeLabel: label,
                           options: pairs.map { $0.option },
                           episodeTitles: allTitles,
                           currentEpisodeIndex: best.index)
    }

    /// 状态提示 3 秒后自动消失
    private func flashStatus(_ text: String) async {
        statusText = text
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        if statusText == text { statusText = nil }
    }
}

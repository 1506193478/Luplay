import SwiftUI

// MARK: - 媒体库 tab（对标稿 v-mine2 深色主列表 + v-cat 浅色分类库页 + v-cont 浅色继续观看页）
// 数据全部真实：片源 libraries()/latest(limit:)（AppEnvironment.providers）+ 本地进度库（AppDatabase）
// + TMDB 海报补全（env.tmdb）。子页面用 @State 切换（iOS 16，不依赖 NavigationStack）。

/// 分类库页目标：某片源下的某个媒体库
struct LibraryCategoryTarget: Equatable {
    let providerId: String
    let providerName: String
    let library: SourceLibrary
}

/// 媒体库 tab 根视图：主列表 + 两个浅色二级页的状态切换
struct LibraryView: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var progressEntries: [PlaybackProgress] = []      // 播放进度（继续观看）
    @State private var libraryEntries: [LibraryEntry] = []           // 我的媒体库收藏（详情页打开过）
    @State private var serverLibs: [String: [SourceLibrary]] = [:]   // provider.id → 媒体库列表
    @State private var posters: [String: URL] = [:]                  // tmdbKey/item.id → TMDB 海报
    @State private var libsLoaded = false
    @State private var categoryTarget: LibraryCategoryTarget? = nil  // 进入分类库页
    @State private var showContinue = false                          // 进入继续观看页

    /// 继续观看 = 未播完（≥95% 视为看完，从列表剔除）
    private var continueEntries: [PlaybackProgress] {
        progressEntries.filter { $0.duration > 0 && $0.position < $0.duration * 0.95 }
    }

    var body: some View {
        ZStack {
            if let target = categoryTarget {
                LibraryCategoryPage(target: target, env: env,
                                    onBack: { withAnimation(.dsEaseOut) { categoryTarget = nil } })
                    .transition(.opacity)
            } else if showContinue {
                LibraryContinuePage(entries: continueEntries, posters: posters,
                                    onBack: { withAnimation(.dsEaseOut) { showContinue = false } })
                    .transition(.opacity)
            } else {
                MineMainView(env: env,
                             serverLibs: serverLibs,
                             libsLoaded: libsLoaded,
                             continueEntries: continueEntries,
                             libraryEntries: libraryEntries,
                             posters: posters,
                             onOpenCategory: { target in
                                 withAnimation(.dsEaseOut) { categoryTarget = target }
                             },
                             onOpenContinue: {
                                 withAnimation(.dsEaseOut) { showContinue = true }
                             })
                    .transition(.opacity)
            }
        }
        .background(Color.dsPage.ignoresSafeArea())
        .task { await loadAll() }
    }

    // MARK: 数据加载（模式照抄 HomeView.loadHome：各源并发 + TMDB 海报补全）

    private func loadAll() async {
        progressEntries = (try? env.database.allProgress()) ?? []
        libraryEntries = (try? env.database.allLibraryEntries()) ?? []
        if !libsLoaded {
            libsLoaded = true
            var map: [String: [SourceLibrary]] = [:]
            await withTaskGroup(of: (String, [SourceLibrary]).self) { group in
                for p in env.providers where p.isConfigured {
                    group.addTask {
                        let libs = (try? await p.libraries()) ?? []
                        return (p.id, libs)
                    }
                }
                for await (pid, libs) in group {
                    map[pid] = libs
                }
            }
            serverLibs = map
        }
        await fillPosters()
    }

    /// TMDB 海报补全：本地库无海报 URL 的条目按标题刮削
    private func fillPosters() async {
        for entry in continueEntries where posters[entry.tmdbKey] == nil {
            let title = entry.tmdbKey.split(separator: "|", maxSplits: 1).first.map(String.init) ?? entry.tmdbKey
            posters[entry.tmdbKey] = await env.tmdb.posterURL(title: title, year: nil)
        }
        for entry in libraryEntries where entry.posterPath == nil && posters[entry.tmdbKey] == nil {
            posters[entry.tmdbKey] = await env.tmdb.posterURL(title: entry.title, year: nil)
        }
    }
}

// MARK: - 主视图（v-mine2：深色 · 服务器分区库列表 + 继续观看 + 我的媒体库）

private struct MineMainView: View {
    let env: AppEnvironment
    let serverLibs: [String: [SourceLibrary]]
    let libsLoaded: Bool
    let continueEntries: [PlaybackProgress]
    let libraryEntries: [LibraryEntry]
    let posters: [String: URL]
    let onOpenCategory: (LibraryCategoryTarget) -> Void
    let onOpenContinue: () -> Void

    @State private var searchOpen = false
    @State private var query = ""
    @State private var selectedServer: String? = nil   // 服务器胶囊筛选（provider.id，nil = 全部）

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                header
                if searchOpen {
                    darkSearchBar
                }
                if !hasAnyResult {
                    Text("没有找到匹配的作品")
                        .font(.system(size: 13))
                        .foregroundStyle(.dsInk2)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 60)
                } else {
                    providerSections
                    continueSection
                    mineLibrarySection
                }
                Color.clear.frame(height: 120)
            }
        }
    }

    // MARK: 顶栏（稿 mine-hd：大标题 + ⌕ + 服务器胶囊）

    private var header: some View {
        HStack(spacing: 12) {
            Text("我的媒体")
                .font(.dsTitle)
                .foregroundStyle(.dsInk)
            Spacer()
            Button {
                withAnimation(.dsEaseOut) { searchOpen = true }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.dsInk)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            serverPill
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    /// 服务器胶囊（Menu 列出已配置源 displayName，可筛选分区）
    private var serverPill: some View {
        Menu {
            Button {
                selectedServer = nil
            } label: {
                Label("全部服务器", systemImage: "tray.full")
            }
            ForEach(allConfigured, id: \.id) { p in
                Button {
                    selectedServer = p.id
                } label: {
                    if selectedServer == p.id {
                        Label(p.displayName, systemImage: "checkmark")
                    } else {
                        Text(p.displayName)
                    }
                }
            }
        } label: {
            GlassSurface(shape: .capsule, interactive: true) {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(colors: [.green, .green.opacity(0.6)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 20, height: 20)
                        .overlay(Text("▶").font(.system(size: 10, weight: .bold)).foregroundStyle(.white))
                    Text(pillTitle)
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(.dsInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.dsInk2)
                }
            }
            .frame(maxWidth: 200, minHeight: 40)
        }
    }

    private var allConfigured: [SourceProvider] {
        env.providers.filter { $0.isConfigured }
    }

    private var pillTitle: String {
        if let id = selectedServer, let p = env.providers.first(where: { $0.id == id }) {
            return p.displayName
        }
        return "全部服务器"
    }

    // MARK: 深色搜索栏（稿 csbar.dk：玻璃底输入框 + 取消）

    private var darkSearchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.dsInk3)
                TextField("搜索", text: $query)
                    .font(.system(size: 14))
                    .foregroundStyle(.dsInk)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.dsGlassFill))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.dsGlassBorder, lineWidth: 1))
            Button("取消") {
                query = ""
                withAnimation(.dsEaseOut) { searchOpen = false }
            }
            .font(.system(size: 14))
            .foregroundStyle(Color.dsAccent)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: 服务器分区（每源一个分区头 + 该源媒体库行）

    private var visibleProviders: [SourceProvider] {
        env.providers.filter { p in
            guard p.isConfigured else { return false }
            if let id = selectedServer { return p.id == id }
            return true
        }
    }

    @ViewBuilder
    private var providerSections: some View {
        if visibleProviders.isEmpty {
            Text("尚未添加媒体服务器 · 前往「设置」添加 Emby / Alist / WebDAV")
                .font(.dsCaption)
                .foregroundStyle(.dsInk3)
                .padding(.horizontal, 20)
                .padding(.top, 30)
        } else {
            ForEach(visibleProviders, id: \.id) { p in
                providerSection(p)
            }
        }
    }

    @ViewBuilder
    private func providerSection(_ p: SourceProvider) -> some View {
        let libs = filteredLibs(for: p)
        if !query.isEmpty && libs.isEmpty {
            // 搜索过滤时空分区直接隐藏
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(p.displayName)
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(.dsInk)
                    Spacer()
                    Text("\(libs.count) 个媒体库")
                        .font(.dsCaption)
                        .foregroundStyle(.dsInk2)
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)

                if libs.isEmpty {
                    Text(libsLoaded ? "暂无可浏览内容" : "正在载入媒体库…")
                        .font(.dsCaption)
                        .foregroundStyle(.dsInk3)
                        .padding(.horizontal, 20)
                } else {
                    VStack(spacing: 0) {
                        ForEach(libs) { lib in
                            libraryRow(p, lib)
                            if lib.id != libs.last?.id { rowDivider }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.dsGlassFill))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.dsGlassBorder, lineWidth: 1))
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    /// 媒体库行（图标圆角方块 + 名称 + chevron，点击进分类库页）
    private func libraryRow(_ p: SourceProvider, _ lib: SourceLibrary) -> some View {
        Button {
            onOpenCategory(LibraryCategoryTarget(providerId: p.id,
                                                 providerName: p.displayName,
                                                 library: lib))
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(colors: CoverPalette.forTitle(lib.name),
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 34, height: 34)
                    .overlay(
                        Image(systemName: libraryIcon(lib.kind))
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.75))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(lib.name)
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(.dsInk)
                        .lineLimit(1)
                    Text(kindName(lib.kind))
                        .font(.dsCaption)
                        .foregroundStyle(.dsInk3)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(.dsInk3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color.dsGlassBorder)
            .frame(height: 0.5)
            .padding(.leading, 58)
    }

    // MARK: 继续观看区（2 列 16:9 缩略卡，标题右侧 › 进二级页）

    @ViewBuilder
    private var continueSection: some View {
        let visible = filteredContinue
        if !query.isEmpty && visible.isEmpty {
            // 搜索过滤时空分区直接隐藏
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("继续观看")
                        .font(.dsSection)
                        .foregroundStyle(.dsInk)
                    Spacer()
                    if !continueEntries.isEmpty {
                        Button(action: onOpenContinue) {
                            HStack(spacing: 3) {
                                Text("\(continueEntries.count)")
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .font(.system(size: 12.5))
                            .foregroundStyle(.dsInk2)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 26)

                if visible.isEmpty {
                    Text("暂无播放记录 · 播放过的内容会出现在这里")
                        .font(.dsCaption)
                        .foregroundStyle(.dsInk3)
                        .padding(.horizontal, 20)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())],
                              spacing: 18) {
                        ForEach(visible, id: \.tmdbKey) { entry in
                            ContinueThumbCard(entry: entry, poster: posters[entry.tmdbKey], onDark: true)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    // MARK: 我的媒体库区（收藏网格，TMDB 海报优先）

    @ViewBuilder
    private var mineLibrarySection: some View {
        let visible = filteredLibraryEntries
        if !query.isEmpty && visible.isEmpty {
            // 搜索过滤时空分区直接隐藏
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("我的媒体库")
                    .font(.dsSection)
                    .foregroundStyle(.dsInk)
                    .padding(.horizontal, 20)
                    .padding(.top, 26)

                if visible.isEmpty {
                    Text("在聚合搜索中打开过详情的影片会出现在这里")
                        .font(.dsCaption)
                        .foregroundStyle(.dsInk3)
                        .padding(.horizontal, 20)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 16) {
                        ForEach(visible, id: \.tmdbKey) { entry in
                            mineLibraryCard(entry)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    private func mineLibraryCard(_ entry: LibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteArt(url: entry.posterPath.flatMap { URL(string: $0) } ?? posters[entry.tmdbKey],
                      title: entry.title)
                .aspectRatio(3 / 4, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(entry.title)
                .font(.dsCardTitle)
                .foregroundStyle(.dsInk)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    // MARK: 过滤与全局空态

    private var filteredContinue: [PlaybackProgress] {
        guard !query.isEmpty else { return continueEntries }
        return continueEntries.filter {
            ProgressEntryHelper.titleParts(of: $0.tmdbKey).title.localizedCaseInsensitiveContains(query)
        }
    }

    private var filteredLibraryEntries: [LibraryEntry] {
        guard !query.isEmpty else { return libraryEntries }
        return libraryEntries.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private func filteredLibs(for p: SourceProvider) -> [SourceLibrary] {
        let libs = serverLibs[p.id] ?? []
        guard !query.isEmpty else { return libs }
        return libs.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var hasAnyResult: Bool {
        if query.isEmpty { return true }
        let libsMatch = visibleProviders.contains { !filteredLibs(for: $0).isEmpty }
        return libsMatch || !filteredContinue.isEmpty || !filteredLibraryEntries.isEmpty
    }

    // MARK: 媒体库类型文案与图标（kind 来自 SourceLibrary）

    private func kindName(_ kind: String) -> String {
        switch kind {
        case "movies": return "电影"
        case "tvshows": return "剧集"
        case "music": return "音乐"
        default: return "混合库"
        }
    }

    private func libraryIcon(_ kind: String) -> String {
        switch kind {
        case "movies": return "film"
        case "tvshows": return "tv"
        case "music": return "music.note"
        default: return "square.grid.2x2"
        }
    }
}

// MARK: - 分类库页（v-cat：浅暖白 · cnav + 搜索栏 + 排序 pill + 竖版海报网格）

private struct LibraryCategoryPage: View {
    let target: LibraryCategoryTarget
    let env: AppEnvironment
    let onBack: () -> Void

    @State private var items: [SourceItem] = []
    @State private var posters: [String: URL] = [:]   // item.id → TMDB 竖版海报（源未自带时补全）
    @State private var loading = true
    @State private var searchOpen = false
    @State private var query = ""
    @State private var sort: CategorySort = .def

    /// 排序（Menu：默认/名称/最新入库）
    enum CategorySort: String, CaseIterable, Identifiable {
        case def = "默认"
        case name = "名称"
        case newest = "最新入库"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            LightNavBar(title: target.library.name,
                        backLabel: "我的媒体",
                        onBack: onBack,
                        onSearch: { withAnimation(.dsEaseOut) { searchOpen = true } })
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if searchOpen {
                        LightSearchBar(query: $query,
                                       onCancel: {
                                           query = ""
                                           withAnimation(.dsEaseOut) { searchOpen = false }
                                       })
                    }
                    sortRow
                    if loading && items.isEmpty {
                        HStack {
                            Spacer()
                            ProgressView().tint(Color.dsLightInk2)
                            Spacer()
                        }
                        .padding(.top, 60)
                    } else if filteredItems.isEmpty {
                        Text("没有找到匹配的作品")
                            .font(.system(size: 13))
                            .foregroundStyle(.dsLightInk2)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 60)
                    } else {
                        posterGrid
                    }
                    Color.clear.frame(height: 60)
                }
                .padding(.horizontal, 16)
            }
        }
        .background(Color.dsLightPage.ignoresSafeArea())
        .task(id: target.library.id) { await loadItems() }
    }

    // MARK: 排序行（稿 srow："排序" + spill 胶囊）

    private var sortRow: some View {
        HStack {
            Text("排序")
                .font(.system(size: 14))
                .foregroundStyle(.dsLightInk2)
            Spacer()
            Menu {
                ForEach(CategorySort.allCases) { s in
                    Button {
                        sort = s
                    } label: {
                        if s == sort {
                            Label(s.rawValue, systemImage: "checkmark")
                        } else {
                            Text(s.rawValue)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(sort.rawValue)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(.dsLightInk2)
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.dsLightInk)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.dsLightInk.opacity(0.08)))
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

    // MARK: 海报网格（自适应 110pt 竖版 3:4 卡片）

    private var posterGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 16) {
            ForEach(filteredItems, id: \.id) { item in
                posterCard(item)
            }
        }
    }

    private func posterCard(_ item: SourceItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteArt(url: item.posterURL ?? posters[item.id], title: item.title)
                .aspectRatio(3 / 4, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(item.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.dsLightInk)
                .lineLimit(1)
            if let year = item.year {
                Text("\(year)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.dsLightInk2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 数据（降级：latest(limit:)，见 loadItems 注释）

    private var filteredItems: [SourceItem] {
        var list = items
        if !query.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }
        switch sort {
        case .def, .newest:
            break   // latest(limit:) 接口本身按入库时间倒序返回，默认与"最新入库"一致
        case .name:
            list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        return list
    }

    private func loadItems() async {
        loading = true
        defer { loading = false }
        // TODO: SourceProvider 协议尚无按库浏览能力（无 browse/children 接口），
        // 分类库页降级展示该源 latest(limit:) 的条目；协议补充 per-library 浏览后替换为真实库内列表。
        guard let provider = env.providers.first(where: { $0.id == target.providerId }) else {
            items = []
            return
        }
        items = (try? await provider.latest(limit: 60)) ?? []
        await fillPosters()
    }

    private func fillPosters() async {
        for item in items where item.posterURL == nil && posters[item.id] == nil {
            posters[item.id] = await env.tmdb.posterURL(title: item.title, year: item.year)
        }
    }
}

// MARK: - 继续观看页（v-cont：浅色 · 2 列 16:9 缩略网格 + 进度条）

private struct LibraryContinuePage: View {
    let entries: [PlaybackProgress]
    let posters: [String: URL]
    let onBack: () -> Void

    @State private var searchOpen = false
    @State private var query = ""
    @State private var sort: ContinueSort = .recent

    /// 排序（Menu：最近观看/进度倒序）
    enum ContinueSort: String, CaseIterable, Identifiable {
        case recent = "最近观看"
        case progressDesc = "进度倒序"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            LightNavBar(title: "继续观看",
                        backLabel: nil,
                        onBack: onBack,
                        onSearch: { withAnimation(.dsEaseOut) { searchOpen = true } })
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if searchOpen {
                        LightSearchBar(query: $query,
                                       onCancel: {
                                           query = ""
                                           withAnimation(.dsEaseOut) { searchOpen = false }
                                       })
                    }
                    sortRow
                    if filteredEntries.isEmpty {
                        Text("没有找到匹配的作品")
                            .font(.system(size: 13))
                            .foregroundStyle(.dsLightInk2)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 60)
                    } else {
                        thumbGrid
                    }
                    Color.clear.frame(height: 60)
                }
                .padding(.horizontal, 16)
            }
        }
        .background(Color.dsLightPage.ignoresSafeArea())
    }

    // MARK: 排序行（同分类库页样式）

    private var sortRow: some View {
        HStack {
            Text("排序")
                .font(.system(size: 14))
                .foregroundStyle(.dsLightInk2)
            Spacer()
            Menu {
                ForEach(ContinueSort.allCases) { s in
                    Button {
                        sort = s
                    } label: {
                        if s == sort {
                            Label(s.rawValue, systemImage: "checkmark")
                        } else {
                            Text(s.rawValue)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(sort.rawValue)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(.dsLightInk2)
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.dsLightInk)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.dsLightInk.opacity(0.08)))
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

    // MARK: 缩略图网格（稿 tgrid：2 列 16:9）

    private var thumbGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())],
                  spacing: 20) {
            ForEach(filteredEntries, id: \.tmdbKey) { entry in
                ContinueThumbCard(entry: entry, poster: posters[entry.tmdbKey], onDark: false)
            }
        }
    }

    private var filteredEntries: [PlaybackProgress] {
        var list = entries
        if !query.isEmpty {
            list = list.filter {
                ProgressEntryHelper.titleParts(of: $0.tmdbKey).title.localizedCaseInsensitiveContains(query)
            }
        }
        switch sort {
        case .recent:
            list.sort { $0.updatedAt > $1.updatedAt }
        case .progressDesc:
            list.sort { a, b in
                let fa = a.duration > 0 ? a.position / a.duration : 0
                let fb = b.duration > 0 ? b.position / b.duration : 0
                return fa > fb
            }
        }
        return list
    }
}

// MARK: - 复用部件

/// 浅色二级页顶栏（稿 cnav：‹ 返回 + 居中标题 + ⌕ 搜索钮）
private struct LightNavBar: View {
    let title: String
    let backLabel: String?
    let onBack: () -> Void
    var onSearch: (() -> Void)? = nil

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.dsLightInk)
                .lineLimit(1)
            HStack(spacing: 0) {
                Button(action: onBack) {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 19, weight: .semibold))
                        if let backLabel {
                            Text(backLabel)
                                .font(.system(size: 15.5, weight: .medium))
                        }
                    }
                    .foregroundStyle(Color.dsAccent)
                }
                .buttonStyle(.plain)
                Spacer()
                if let onSearch {
                    Button {
                        onSearch()
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 19))
                            .foregroundStyle(Color.dsAccent)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }
}

/// 浅色搜索栏（稿 csbar：白底圆角输入 + 蓝色取消）
private struct LightSearchBar: View {
    @Binding var query: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.dsLightInk2)
                TextField("搜索", text: $query)
                    .font(.system(size: 14))
                    .foregroundStyle(.dsLightInk)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.dsLightCard))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.dsLightBorder, lineWidth: 1))
            Button("取消", action: onCancel)
                .font(.system(size: 14))
                .foregroundStyle(Color.dsAccent)
        }
        .padding(.bottom, 6)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// 继续观看缩略卡（16:9 + 底部进度条 + 剩余时长角标）；主列表深色 / 二级页浅色共用
private struct ContinueThumbCard: View {
    let entry: PlaybackProgress
    let poster: URL?
    let onDark: Bool

    var body: some View {
        let parts = ProgressEntryHelper.titleParts(of: entry.tmdbKey)
        let fraction = entry.duration > 0 ? min(1, entry.position / entry.duration) : 0
        VStack(alignment: .leading, spacing: 7) {
            RemoteArt(url: poster, title: parts.title)
                .aspectRatio(16 / 9, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottomLeading) {
                    if let remain = ProgressEntryHelper.remainingText(for: entry) {
                        Text(remain)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.black.opacity(0.5)))
                            .padding(8)
                    }
                }
                .overlay(alignment: .bottom) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.25))
                            Rectangle().fill(Color.dsAccent)
                                .frame(width: geo.size.width * fraction)
                        }
                    }
                    .frame(height: 3)
                }
            Text(parts.title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(onDark ? Color.dsInk : Color.dsLightInk)
                .lineLimit(1)
            if let episode = parts.episode {
                Text(episode)
                    .font(.system(size: 11))
                    .foregroundStyle(onDark ? Color.dsInk2 : Color.dsLightInk2)
                    .lineLimit(1)
            }
        }
    }
}

/// 进度条目小工具（tmdbKey 形如 "标题|集标签"，标题部分用于展示与搜索）
private enum ProgressEntryHelper {
    /// 解析标题与集标签（无集标签时 episode 为 nil）
    static func titleParts(of key: String) -> (title: String, episode: String?) {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        return (parts.first ?? key, parts.count > 1 ? parts[1] : nil)
    }

    /// 剩余时长文案（稿 tstamp 角标）；无有效进度时返回 nil
    static func remainingText(for entry: PlaybackProgress) -> String? {
        guard entry.duration > 0, entry.position < entry.duration else { return nil }
        let minutes = Int((entry.duration - entry.position) / 60)
        return minutes > 0 ? "还剩 \(minutes) 分钟" : nil
    }
}

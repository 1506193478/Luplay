import SwiftUI

// MARK: - 搜索页状态模型（稿 v-search）

/// 分段模式：媒体库（聚合搜索）/ TMDB（直搜）
private enum SearchMode {
    case library
    case tmdb
}

/// 排序（稿 smenu：最近添加 / 名称 / A-Z）
private enum SearchSort: String, CaseIterable, Identifiable {
    case recent = "最近添加"
    case name = "名称"
    case az = "A-Z"
    var id: String { rawValue }
}

/// 类型筛选（稿 sfilter chips；仅作用于已显示结果，纯前端过滤）
private enum ItemTypeFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case movie = "电影"
    case series = "剧集"
    var id: String { rawValue }
    func matches(_ type: SourceItem.ItemType) -> Bool {
        switch self {
        case .all: return true
        case .movie: return type == .movie
        case .series: return type == .series
        }
    }
}

/// 年代筛选（按条目年份前端过滤）
private enum EraFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case y2020s = "2020s"
    case y2010s = "2010s"
    case y2000s = "2000s"
    case older = "更早"
    var id: String { rawValue }
    /// 无年份条目仅在“全部”下显示
    func matches(_ year: Int?) -> Bool {
        guard let year else { return self == .all }
        switch self {
        case .all: return true
        case .y2020s: return year >= 2020
        case .y2010s: return (2010...2019).contains(year)
        case .y2000s: return (2000...2009).contains(year)
        case .older: return year < 2000
        }
    }
}

/// 服务器分组（结果按片源服务器分组，组内行按所选排序）
private struct ServerGroup: Identifiable {
    let id: String          // providerId
    let name: String
    let rows: [SourceRow]
}

/// 结果行：源条目 + 所属聚合结果（详情页入口需要整份聚合结果）
private struct SourceRow: Identifiable {
    let item: SourceItem
    let result: SearchAggregator.AggregatedResult
    var id: String { item.id }
}

/// 稿 v-search 选中态深色 #3a3835（分段/工具钮/chips 共用）
private let searchDark = Color(red: 0.227, green: 0.220, blue: 0.208)

/// 聚合搜索页（对标稿 v-search）：浅暖磨砂底 + sblob 色斑 + 顶部分段
/// + 底部玻璃搜索栏（⌕ 输入 + ⏱排序 ☰筛选 🔗链接）+ 服务器分组结果
/// 业务链路保留：防抖聚合搜索（SearchAggregator）→ 详情页 AggregateDetailView → onPlay
struct SearchView: View {
    var openPlayer: (PlayRequest) -> Void = { _ in }
    @EnvironmentObject private var env: AppEnvironment
    @FocusState private var inputFocused: Bool

    @State private var query = ""
    @State private var mode: SearchMode = .library
    @State private var sort: SearchSort = .recent
    @State private var typeFilter: ItemTypeFilter = .all
    @State private var eraFilter: EraFilter = .all
    @State private var showSortMenu = false
    @State private var showFilterPanel = false
    @State private var detailTarget: SearchAggregator.AggregatedResult?
    @State private var showURLPanel = false
    @State private var tmdbResults: [TMDBSearchHit] = []
    @State private var tmdbSearching = false

    private var aggregator: SearchAggregator { env.aggregator }

    // MARK: 主结构

    var body: some View {
        ZStack(alignment: .bottom) {
            frostedBackground
            mainContent
            bottomBar
            sortMenuLayer
            filterLayer
        }
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
        // 防抖搜索：query/模式变化 → 停顿 350ms 后发起（task(id:) 自动取消旧任务）
        .task(id: searchKey) { await runSearchTask() }
    }

    private var searchKey: String { "\(mode == .library ? "lib" : "tmdb")|\(query)" }

    // MARK: 背景浅暖磨砂 + sblob 模糊色斑（装饰不抢内容）

    private var frostedBackground: some View {
        Color.dsLightPage
            .overlay(alignment: .topLeading) {
                blob(Color(red: 1.0, green: 0.72, blue: 0.55).opacity(0.34), 300)
                    .offset(x: 60, y: 50)
            }
            .overlay(alignment: .topTrailing) {
                blob(Color(red: 1.0, green: 0.89, blue: 0.67).opacity(0.40), 260)
                    .offset(x: -30, y: 150)
            }
            .overlay(alignment: .bottomLeading) {
                blob(Color(red: 0.73, green: 0.88, blue: 0.73).opacity(0.32), 290)
                    .offset(x: 40, y: -130)
            }
            .overlay(alignment: .bottomTrailing) {
                blob(Color(red: 0.82, green: 0.84, blue: 0.94).opacity(0.30), 250)
                    .offset(x: -30, y: -50)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    /// 稿 sblob：大圆模糊色斑
    private func blob(_ color: Color, _ size: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .blur(radius: 50)
    }

    // MARK: 顶栏 snav（标题 + 分段 + 清空钮）

    private var navBar: some View {
        HStack(spacing: 12) {
            Text("搜索")
                .font(.system(size: 24, weight: .heavy))
                .foregroundStyle(.dsLightInk)
            segs
            Spacer(minLength: 0)
            closeButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// 稿 segs：媒体库 / TMDB 分段胶囊（选中深底白字）
    private var segs: some View {
        HStack(spacing: 2) {
            segButton("媒体库", selected: mode == .library) { switchMode(.library) }
            segButton("TMDB", selected: mode == .tmdb) { switchMode(.tmdb) }
        }
        .padding(3)
        .background(Capsule().fill(Color(red: 0.906, green: 0.886, blue: 0.851)))
    }

    private func segButton(_ title: String, selected: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(selected ? Color.white : .dsLightInk2)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(selected
                    ? AnyShapeStyle(searchDark)
                    : AnyShapeStyle(Color.clear)))
        }
        .buttonStyle(.plain)
    }

    /// 切换分段（TMDB 段下隐藏排序/筛选，并收起浮层）
    private func switchMode(_ newMode: SearchMode) {
        guard mode != newMode else { return }
        withAnimation(.dsSpring) { mode = newMode }
        showSortMenu = false
        showFilterPanel = false
        inputFocused = false
    }

    /// 稿 sclose ✕：搜索页是常驻 tab，安全行为 = 清空输入 + 收起键盘
    private var closeButton: some View {
        Button {
            query = ""
            aggregator.results = []
            tmdbResults = []
            inputFocused = false
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.dsLightInk)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.dsLightInk.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }

    // MARK: 主内容（空态居中 / 结果分组列表）

    private var queryTrimmed: String { query.trimmingCharacters(in: .whitespaces) }

    private var isSearchingNow: Bool {
        mode == .library ? aggregator.isSearching : tmdbSearching
    }

    private var hasVisibleResults: Bool {
        guard !queryTrimmed.isEmpty else { return false }
        return mode == .library ? !serverGroups.isEmpty : !tmdbResults.isEmpty
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            navBar
            if hasVisibleResults {
                resultList
            } else {
                Spacer(minLength: 0)
                centerState
                    .padding(.horizontal, 32)
                    .padding(.bottom, 40)
                Spacer(minLength: 0)
                Color.clear.frame(height: 90)   // 给底部玻璃搜索栏留位
            }
        }
    }

    /// 稿 sempty：大圆 ⌕ + 标题 + 副标（搜索中显示进度）
    @ViewBuilder
    private var centerState: some View {
        if isSearchingNow {
            VStack(spacing: 12) {
                ProgressView().tint(.dsLightInk2)
                Text(mode == .library ? "正在聚合全部片源…" : "正在搜索 TMDB…")
                    .font(.dsCaption)
                    .foregroundStyle(.dsLightInk2)
            }
        } else {
            VStack(spacing: 0) {
                Circle()
                    .fill(Color.dsLightInk.opacity(0.13))
                    .frame(width: 64, height: 64)
                    .overlay(
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 26))
                            .foregroundStyle(.dsLightInk2)
                    )
                    .padding(.bottom, 16)
                Text(emptyTitle)
                    .font(.system(size: 19, weight: .heavy))
                    .foregroundStyle(.dsLightInk)
                Text(emptySubtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.dsLightInk2)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
        }
    }

    private var emptyTitle: String {
        if mode == .tmdb {
            if queryTrimmed.isEmpty { return "搜索 TMDB" }
            if !env.tmdb.isConfigured { return "TMDB 直搜需要配置密钥" }
            return "没有命中结果"
        }
        return queryTrimmed.isEmpty ? "搜索全部服务器" : "没有命中结果"
    }

    private var emptySubtitle: String {
        if mode == .tmdb {
            if queryTrimmed.isEmpty { return "点开作品，会在你的服务器里找片源" }
            if !env.tmdb.isConfigured { return "前往 设置 → 服务密钥，填入 TMDB API Key" }
            return "试试其他关键词"
        }
        return queryTrimmed.isEmpty
            ? "结果按服务器分组显示，当前服务器在最前"
            : "确认已在设置中配置并登录片源服务器"
    }

    // MARK: 结果 sres（白色圆角卡片分组列表）

    private var resultList: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                if mode == .library {
                    ForEach(serverGroups) { group in
                        serverSection(group)
                    }
                } else {
                    tmdbSection
                }
                Color.clear.frame(height: 110)   // 底部留出搜索栏空间
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    /// 聚合结果展平为行（保留所属聚合结果供详情页使用）
    private var sourceRows: [SourceRow] {
        aggregator.results.flatMap { result in
            result.items.map { SourceRow(item: $0, result: result) }
        }
    }

    /// 筛选仅作用于已显示结果（类型 + 年代，纯前端过滤）
    private var filteredRows: [SourceRow] {
        sourceRows.filter { row in
            typeFilter.matches(row.item.type) && eraFilter.matches(row.item.year)
        }
    }

    /// 按服务器分组；组顺序跟随 env.providers（当前/首个配置的服务器在前）
    private var serverGroups: [ServerGroup] {
        var buckets: [String: [SourceRow]] = [:]
        var order: [String] = []
        for row in filteredRows {
            let pid = row.item.providerId
            if buckets[pid] == nil { order.append(pid) }
            buckets[pid, default: []].append(row)
        }
        let ids = env.providers.map(\.id)
        return order
            .sorted { position(of: $0, in: ids) < position(of: $1, in: ids) }
            .map { pid in
                ServerGroup(id: pid,
                            name: env.providers.first { $0.id == pid }?.displayName ?? pid,
                            rows: sortRows(buckets[pid] ?? []))
            }
    }

    private func position(of id: String, in ids: [String]) -> Int {
        ids.firstIndex(of: id) ?? Int.max
    }

    /// 组内排序（最近添加 = 服务器返回顺序；名称 = 本地化排序；A-Z = 字典序）
    private func sortRows(_ rows: [SourceRow]) -> [SourceRow] {
        switch sort {
        case .recent:
            return rows
        case .name:
            return rows.sorted {
                $0.item.title.localizedStandardCompare($1.item.title) == .orderedAscending
            }
        case .az:
            return rows.sorted { $0.item.title.lowercased() < $1.item.title.lowercased() }
        }
    }

    /// 服务器分组段：组头（服务器名 + 命中数）+ 白色圆角卡片行列表
    private func serverSection(_ group: ServerGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(group.name)
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(.dsLightInk)
                Text("\(group.rows.count) 个结果")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.dsLightInk2)
                Spacer(minLength: 0)
            }
            groupCard {
                ForEach(group.rows) { row in
                    groupRow(row)
                    if row.id != group.rows.last?.id {
                        Rectangle().fill(.dsLightBorder).frame(height: 0.5)
                            .padding(.leading, 68)
                    }
                }
            }
        }
    }

    /// 白色圆角分组卡片（浅色卡片语言，对齐设置页 lightCard）
    @ViewBuilder
    private func groupCard(@ViewBuilder rows: () -> some View) -> some View {
        VStack(spacing: 0) { rows() }
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.dsLightCard))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.dsLightBorder, lineWidth: 1))
    }

    /// 结果行：竖版海报小图 + 标题 + 年份/类型 + chevron；点行进详情
    private func groupRow(_ row: SourceRow) -> some View {
        Button {
            detailTarget = row.result
        } label: {
            HStack(spacing: 12) {
                RowPoster(item: row.item)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.item.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.dsLightInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(rowSubtitle(row.item))
                        .font(.system(size: 12))
                        .foregroundStyle(.dsLightInk2)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundStyle(.dsLightInk2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func rowSubtitle(_ item: SourceItem) -> String {
        var parts: [String] = []
        if let y = item.year { parts.append("\(y)") }
        parts.append(item.type == .series ? "剧集" : "电影")
        return parts.joined(separator: " · ")
    }

    // MARK: TMDB 直搜段（单分组结果）

    @ViewBuilder
    private var tmdbSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("TMDB")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(.dsLightInk)
                Text("\(tmdbResults.count) 个结果")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.dsLightInk2)
                Spacer(minLength: 0)
            }
            groupCard {
                ForEach(tmdbResults) { hit in
                    tmdbRow(hit)
                    if hit.id != tmdbResults.last?.id {
                        Rectangle().fill(.dsLightBorder).frame(height: 0.5)
                            .padding(.leading, 68)
                    }
                }
            }
        }
    }

    /// TMDB 行：点开作品回媒体库按标题聚合找片源（稿副标“点开作品，会在你的服务器里找片源”）
    private func tmdbRow(_ hit: TMDBSearchHit) -> some View {
        Button {
            withAnimation(.dsSpring) { mode = .library }
            query = hit.title
            inputFocused = false
        } label: {
            HStack(spacing: 12) {
                RemoteArt(url: hit.posterURL, title: hit.title)
                    .frame(width: 44, height: 62)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(hit.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.dsLightInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(tmdbSubtitle(hit))
                        .font(.system(size: 12))
                        .foregroundStyle(.dsLightInk2)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundStyle(.dsLightInk2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func tmdbSubtitle(_ hit: TMDBSearchHit) -> String {
        var parts: [String] = []
        if let y = hit.year { parts.append("\(y)") }
        parts.append(hit.mediaType == "tv" ? "剧集" : "电影")
        return parts.joined(separator: " · ")
    }

    // MARK: 底部玻璃搜索栏 sbar（常驻：⌕ + 输入 + 工具钮）

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17))
                .foregroundStyle(.dsLightInk2)
            TextField("影片、剧集或演职人员", text: $query)
                .font(.system(size: 15))
                .foregroundStyle(.dsLightInk)
                .submitLabel(.search)
                .focused($inputFocused)
            // ⏱ 排序（仅媒体库段）
            toolButton(icon: "timer", active: showSortMenu, visible: mode == .library) {
                toggleSortMenu()
            }
            // ☰ 筛选（仅媒体库段）
            toolButton(icon: "line.3.horizontal", active: showFilterPanel, visible: mode == .library) {
                toggleFilter()
            }
            // 🔗 链接播放（保留既有功能入口）
            toolButton(icon: "link", active: false, visible: true) {
                withAnimation(.dsEaseOut) { showURLPanel = true }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 54)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.42))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.dsLightBorder, lineWidth: 0.5)
        )
        .shadow(color: Color(red: 0.31, green: 0.27, blue: 0.20).opacity(0.14), radius: 15, y: 8)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    /// 稿 sbar .tool：34 圆形工具钮，激活态深底白字
    private func toolButton(icon: String, active: Bool, visible: Bool,
                            action: @escaping () -> Void) -> some View {
        Group {
            if visible {
                Button(action: action) {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundStyle(active ? Color.white : .dsLightInk)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(active
                            ? AnyShapeStyle(searchDark)
                            : AnyShapeStyle(Color.dsLightInk.opacity(0.14))))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func toggleSortMenu() {
        withAnimation(.dsEaseOut) {
            showSortMenu.toggle()
            showFilterPanel = false
        }
    }

    private func toggleFilter() {
        withAnimation(.dsEaseOut) {
            showFilterPanel.toggle()
            showSortMenu = false
        }
    }

    // MARK: 排序菜单 smenu（悬于搜索栏右上方）

    @ViewBuilder
    private var sortMenuLayer: some View {
        if showSortMenu {
            // 点击菜单外关闭
            Color.clear
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onTapGesture {
                    withAnimation(.dsEaseOut) { showSortMenu = false }
                }
            VStack(spacing: 0) {
                ForEach(SearchSort.allCases) { option in
                    sortRow(option)
                }
            }
            .frame(width: 200)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.988, green: 0.984, blue: 0.976).opacity(0.97)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.dsLightBorder, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.14), radius: 18, y: 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 20)
            .padding(.bottom, 76)
            .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
        }
    }

    private func sortRow(_ option: SearchSort) -> some View {
        Button {
            withAnimation(.dsSpring) { sort = option }
            // 对稿：选中后短暂停留再收起
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.dsEaseOut) { showSortMenu = false }
            }
        } label: {
            HStack {
                Text(option.rawValue)
                    .font(.system(size: 14))
                    .foregroundStyle(.dsLightInk)
                Spacer(minLength: 0)
                if sort == option {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.dsLightInk)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 筛选面板 sfilter（底部滑入白面板：类型 + 年代 chips）

    @ViewBuilder
    private var filterLayer: some View {
        if showFilterPanel {
            // 点击面板外关闭
            Color.clear
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onTapGesture {
                    withAnimation(.dsEaseOut) { showFilterPanel = false }
                }
            VStack(alignment: .leading, spacing: 18) {
                Text("筛选")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(.dsLightInk)
                filterGroup(label: "类型") {
                    filterChip("全部", selected: typeFilter == .all) { typeFilter = .all }
                    filterChip("电影", selected: typeFilter == .movie) { typeFilter = .movie }
                    filterChip("剧集", selected: typeFilter == .series) { typeFilter = .series }
                }
                filterGroup(label: "年代") {
                    filterChip("全部", selected: eraFilter == .all) { eraFilter = .all }
                    filterChip("2020s", selected: eraFilter == .y2020s) { eraFilter = .y2020s }
                    filterChip("2010s", selected: eraFilter == .y2010s) { eraFilter = .y2010s }
                    filterChip("2000s", selected: eraFilter == .y2000s) { eraFilter = .y2000s }
                    filterChip("更早", selected: eraFilter == .older) { eraFilter = .older }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TopRoundedShape(radius: 22)
                .fill(Color(red: 0.980, green: 0.976, blue: 0.965).opacity(0.97)))
            .overlay(TopRoundedShape(radius: 22)
                .strokeBorder(.dsLightBorder, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.10), radius: 18, y: -6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// 稿 fgroup：小标签 + chips 流式排布
    private func filterGroup<Content: View>(label: String,
                                            @ViewBuilder chips: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.dsLightInk2)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), alignment: .leading)],
                      alignment: .leading, spacing: 8) {
                chips()
            }
        }
    }

    /// 稿 fchip：胶囊 chip，选中深底白字
    private func filterChip(_ label: String, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? Color.white : .dsLightInk)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(selected
                    ? AnyShapeStyle(searchDark)
                    : AnyShapeStyle(Color.dsLightInk.opacity(0.10))))
                .animation(.dsSpring, value: selected)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 搜索执行（保留聚合链路 + 防抖）

    private func runSearchTask() async {
        let q = queryTrimmed
        guard !q.isEmpty else {
            aggregator.results = []
            tmdbResults = []
            return
        }
        // 防抖：输入停顿 350ms 后再发起（快速输入时旧任务被自动取消）
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !Task.isCancelled else { return }
        if mode == .library {
            await aggregator.search(query: q, providers: env.providers)
            if Task.isCancelled { return }   // 已被更新的输入打断：丢弃本次过期结果
        } else {
            // TMDB 直搜：未配置密钥时清空并显示配置提示
            guard env.tmdb.isConfigured else {
                tmdbResults = []
                return
            }
            let hits = await env.tmdb.searchMulti(query: q)
            if Task.isCancelled { return }
            tmdbResults = hits
        }
    }
}

// MARK: - 小组件

/// 行海报：源自带海报优先，缺省时 TMDB 刮削补全，最后落标题渐变占位
private struct RowPoster: View {
    let item: SourceItem
    @EnvironmentObject private var env: AppEnvironment
    @State private var tmdbURL: URL?

    var body: some View {
        RemoteArt(url: item.posterURL ?? tmdbURL, title: item.title)
            .frame(width: 44, height: 62)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .task {
                guard item.posterURL == nil, tmdbURL == nil else { return }
                tmdbURL = await env.tmdb.posterURL(title: item.title, year: item.year)
            }
    }
}

/// 顶部圆角形状（稿 sfilter 22 圆角白面板；iOS 16 兼容，避免 16.4+ 的 UnevenRoundedRectangle）
/// 实现 InsettableShape 以支持 strokeBorder
private struct TopRoundedShape: InsettableShape {
    var radius: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        return Path { p in
            p.move(to: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
            p.addQuadCurve(to: CGPoint(x: r.minX + radius, y: r.minY),
                           control: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + radius),
                           control: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.closeSubpath()
        }
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var s = self
        s.insetAmount += amount
        return s
    }
}

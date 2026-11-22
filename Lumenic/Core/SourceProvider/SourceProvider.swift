import Foundation

// MARK: - 片源协议与数据模型（方案 §4.1）

struct SourceItem: Identifiable, Hashable {
    let id: String
    let providerId: String
    let title: String
    let year: Int?
    let type: ItemType
    enum ItemType { case movie, series }
    var posterURL: URL? = nil     // 源自带竖版海报（Emby ImageTags）；nil 时由 TMDB 补全
    var backdropURL: URL? = nil   // 源自带横版背景（hero 轮播用）
}

// MARK: - 浏览能力（首页"我的媒体/最新入库"真实数据；默认空实现）

/// 媒体库（Emby Views / 文件型源根目录）
struct SourceLibrary: Identifiable, Hashable {
    let id: String        // "\(providerId)|\(libraryId)"
    let name: String
    var kind: String = "mixed"   // movies / tvshows / mixed
}

extension SourceProvider {
    /// 媒体库列表（Emby=/Users/{id}/Views；文件型源=单个根目录库）
    func libraries() async throws -> [SourceLibrary] { [] }
    /// 最新入库条目（Emby=/Items/Latest；文件型源=根目录浅层扫描）
    func latest(limit: Int) async throws -> [SourceItem] { [] }
}

struct Episode: Identifiable, Hashable {
    let id: String
    let season: Int
    let episode: Int
    let title: String
}

/// 片源对比卡数据（聚合面板行：HDR/分辨率/码率/服务器/推荐内核）
struct StreamInfo {
    let url: URL
    let headers: [String: String]
    let container: String      // mkv / mp4 / m3u8 / ts
    let codec: String?         // hevc / avc / ...
    let resolution: String     // 4K60 / 1080P
    let bitrateMbps: Double
    let hdr: String            // SDR / HDR10 / 杜比视界
    let recommendedEngine: EngineKind

    var qualityScore: Int {
        // 推荐“算法”首版：HDR > 分辨率 > 码率（方案 §4.2）
        let hdrScore = hdr.contains("杜比") ? 3 : (hdr == "HDR10" ? 2 : 0)
        let resScore = resolution.contains("4K") ? 2 : 1
        let brScore = bitrateMbps >= 20 ? 2 : (bitrateMbps >= 8 ? 1 : 0)
        return hdrScore * 100 + resScore * 10 + brScore
    }
}

protocol SourceProvider {
    var id: String { get }
    var displayName: String { get }
    var isConfigured: Bool { get }
    func search(_ query: String) async throws -> [SourceItem]
    func episodes(of item: SourceItem) async throws -> [Episode]
    func streamURL(of episode: Episode) async throws -> StreamInfo
}

// MARK: - 聚合搜索（方案 §4.2：并发多源 + TMDB 归一化）

@MainActor
final class SearchAggregator: ObservableObject {
    @Published var isSearching = false
    @Published var results: [AggregatedResult] = []

    struct AggregatedResult: Identifiable {
        let id: String                 // TMDB ID 或标题归一化 key
        let title: String
        let items: [SourceItem]
    }

    private let tmdb: TMDBService

    init(tmdb: TMDBService) { self.tmdb = tmdb }

    func search(query: String, providers: [SourceProvider]) async {
        isSearching = true
        defer { isSearching = false }

        await withTaskGroup(of: [SourceItem].self) { group in
            for p in providers where p.isConfigured {
                group.addTask { (try? await p.search(query)) ?? [] }
            }
            var all: [SourceItem] = []
            for await r in group { all += r }
            await self.merge(all, query: query)
        }
    }

    /// 归一化：优先 TMDB find 合并；不可用时退化为标题精确归一
    private func merge(_ items: [SourceItem], query: String) async {
        var buckets: [String: [SourceItem]] = [:]
        for item in items {
            let key = await tmdb.canonicalKey(title: item.title, year: item.year)
                ?? item.title.trimmingCharacters(in: .whitespaces).lowercased()
            buckets[key, default: []].append(item)
        }
        results = buckets
            .filter { $0.value.count > 0 }
            .map { AggregatedResult(id: $0.key, title: $0.value.first?.title ?? query, items: $0.value) }
            .sorted { $0.items.count > $1.items.count }
    }
}

// MARK: - 播放请求（M4：真实片源 → 播放器，多源对比）

/// 一条可播放的片源选项（服务器 × 单集 → 播放地址 + 媒体信息）
struct StreamOption: Identifiable {
    let id: String          // itemId|episodeId 组合
    let providerId: String
    let serverName: String
    var info: StreamInfo    // var：续播/换源前可通过 refresh 刷新为最新直链
    /// 直链时效刷新（Alist raw_url 有时效）：重新取流信息；nil 表示链接长期有效
    var refresh: (() async throws -> StreamInfo)? = nil
    /// 剧集切换通道：按集序号取该源对应集的流信息；nil = 电影/单集
    var episodeStream: ((Int) async throws -> StreamInfo)? = nil
}

struct PlayRequest: Identifiable {
    let id = UUID()
    let title: String
    let episodeLabel: String
    let options: [StreamOption]
    /// 全集标签列表（仅剧集，nil = 电影）：用于上下集切换与选集面板
    var episodeTitles: [String]? = nil
    /// 当前播放的集序号（episodeTitles 下标）
    var currentEpisodeIndex: Int = 0

    /// 质量分最高的片源（默认选中）
    var bestOption: StreamOption? {
        options.max { $0.info.qualityScore < $1.info.qualityScore }
    }
}

extension SourceProvider {
    /// 连接测试（设置页用）
    func testConnection() async throws -> String { throw ProviderError.notImplemented }
}

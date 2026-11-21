import Foundation

// MARK: - 片源协议与数据模型（方案 §4.1）

struct SourceItem: Identifiable, Hashable {
    let id: String
    let providerId: String
    let title: String
    let year: Int?
    let type: ItemType
    enum ItemType { case movie, series }
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
                group.addTask { try? await p.search(query) ?? [] }
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

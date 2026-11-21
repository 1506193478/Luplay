import Foundation

/// TMDB 元数据服务：标题归一化 + 海报刮削（API Key 在设置中配置，Keychain 存储）
final class TMDBService {
    private let apiKey: String?   // M4：从 Keychain 读取
    private let baseURL = "https://api.themoviedb.org/3"
    private var cache: [String: String] = [:]
    private let lock = NSLock()

    /// 归一化 key：TMDB ID；查不到时返回 nil（调用方退化为标题归一）
    func canonicalKey(title: String, year: Int?) async -> String? {
        guard let apiKey else { return nil }
        let key = "\(title)|\(year ?? 0)"
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[key] { return hit }

        var comps = URLComponents(string: "\(baseURL)/search/multi")!
        comps.queryItems = [
            .init(name: "api_key", value: apiKey),
            .init(name: "query", value: title),
        ]
        if let year { comps.queryItems!.append(.init(name: "first_air_date_year", value: "\(year)")) }
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (obj["results"] as? [[String: Any]])?.first,
              let tmdbID = first["id"] as? Int
        else { return nil }

        let result = "tmdb:\(tmdbID)"
        lock.lock(); cache[key] = result; lock.unlock()
        return result
    }
}

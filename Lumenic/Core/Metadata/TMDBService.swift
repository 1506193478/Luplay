import Foundation

/// TMDB 元数据服务：标题归一化 + 海报刮削（API Key 在设置中配置，Keychain 存储）
final class TMDBService {
    private static let apiKeyKey = "com.luplay.tmdb.apiKey"
    private let baseURL = "https://api.themoviedb.org/3"
    private let imageBaseURL = "https://image.tmdb.org/t/p/w500"
    private var cache: [String: String] = [:]      // 标题|年 → tmdb:id
    private var posterCache: [String: String?] = [:]  // 标题|年 → posterPath
    private var backdropCache: [String: String?] = [:]  // 标题|年 → backdropPath
    private let lock = NSLock()

    var apiKey: String? { KeychainStore.shared.string(for: Self.apiKeyKey) }
    var isConfigured: Bool { !(apiKey ?? "").isEmpty }
    func saveApiKey(_ key: String) { KeychainStore.shared.setString(key, for: Self.apiKeyKey) }

    /// 归一化 key：TMDB ID；查不到时返回 nil（调用方退化为标题归一）
    func canonicalKey(title: String, year: Int?) async -> String? {
        guard let apiKey, !apiKey.isEmpty else { return nil }
        let key = "\(title)|\(year ?? 0)"
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[key] { return hit }

        guard let obj = await search(title: title, year: year) else { return nil }
        guard let tmdbID = obj["id"] as? Int else { return nil }

        let result = "tmdb:\(tmdbID)"
        lock.lock(); cache[key] = result; lock.unlock()
        return result
    }

    /// 海报地址：search/multi 取 poster_path；未配置或查不到返回 nil（调用方落渐变占位）
    func posterURL(title: String, year: Int?) async -> URL? {
        guard let apiKey, !apiKey.isEmpty else { return nil }
        let key = "\(title)|\(year ?? 0)"
        lock.lock()
        if let cached = posterCache[key] {
            lock.unlock()
            return cached.flatMap { URL(string: imageBaseURL + $0) }
        }
        lock.unlock()

        let path: String? = await search(title: title, year: year)?["poster_path"] as? String
        lock.lock(); posterCache[key] = path; lock.unlock()
        return path.flatMap { URL(string: imageBaseURL + $0) }
    }

    /// 横版背景图地址（search/multi 取 backdrop_path；详情页背景用，比例匹配不裁切变形）
    func backdropURL(title: String, year: Int?) async -> URL? {
        guard let apiKey, !apiKey.isEmpty else { return nil }
        let key = "\(title)|\(year ?? 0)"
        lock.lock()
        if let cached = backdropCache[key] {
            lock.unlock()
            return cached.flatMap { URL(string: imageBaseURL + $0) }
        }
        lock.unlock()

        let path: String? = await search(title: title, year: year)?["backdrop_path"] as? String
        lock.lock(); backdropCache[key] = path; lock.unlock()
        return path.flatMap { URL(string: imageBaseURL + $0) }
    }

    private func search(title: String, year: Int?) async -> [String: Any]? {
        guard let apiKey else { return nil }
        var comps = URLComponents(string: "\(baseURL)/search/multi")!
        var items = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: title),
            URLQueryItem(name: "language", value: "zh-CN"),
        ]
        if let year { items.append(.init(name: "first_air_date_year", value: "\(year)")) }
        comps.queryItems = items
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return ((obj["results"] as? [[String: Any]])?.first) ?? nil
    }
}

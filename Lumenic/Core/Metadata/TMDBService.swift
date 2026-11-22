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

    /// 详情元数据缓存：标题|年 → 详情（nil 也缓存，避免反复打接口）
    private var detailsCache: [String: TMDBDetails?] = [:]

    /// 详情元数据：search/multi 定位 id+类型后一次拉齐 credits/images/similar（详情页对稿数据源）
    func details(title: String, year: Int?) async -> TMDBDetails? {
        guard let apiKey, !apiKey.isEmpty else { return nil }
        let key = "\(title)|\(year ?? 0)"
        lock.lock()
        if let cached = detailsCache[key] { lock.unlock(); return cached }
        lock.unlock()

        guard let hit = await search(title: title, year: year),
              let tmdbID = hit["id"] as? Int else {
            lock.lock(); detailsCache[key] = TMDBDetails?.none; lock.unlock()
            return nil
        }
        let mediaType = (hit["media_type"] as? String) == "tv" ? "tv" : "movie"

        var comps = URLComponents(string: "\(baseURL)/\(mediaType)/\(tmdbID)")!
        comps.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "language", value: "zh-CN"),
            URLQueryItem(name: "append_to_response", value: "credits,images,similar"),
            URLQueryItem(name: "include_image_language", value: "zh,null,en"),
        ]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            lock.lock(); detailsCache[key] = TMDBDetails?.none; lock.unlock()
            return nil
        }

        func person(_ raw: [String: Any], role: String) -> TMDBPerson? {
            guard let id = raw["id"] as? Int, let name = raw["name"] as? String else { return nil }
            let profile = (raw["profile_path"] as? String)
                .flatMap { URL(string: "https://image.tmdb.org/t/p/w185\($0)") }
            return TMDBPerson(id: id, name: name, role: role, profileURL: profile)
        }
        let credits = obj["credits"] as? [String: Any] ?? [:]
        let castRaw = credits["cast"] as? [[String: Any]] ?? []
        let cast: [TMDBPerson] = castRaw.prefix(20).compactMap {
            person($0, role: ($0["character"] as? String) ?? "")
        }
        let crewRaw = credits["crew"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        let crew: [TMDBPerson] = crewRaw.compactMap { raw -> TMDBPerson? in
            guard let job = raw["job"] as? String, let p = person(raw, role: job),
                  seen.insert("\(p.name)|\(p.role)").inserted else { return nil }
            return p
        }
        let genreNames: [String] = (obj["genres"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let stillRaw = (obj["images"] as? [String: Any])?["backdrops"] as? [[String: Any]] ?? []
        let stills: [URL] = stillRaw.prefix(10).compactMap {
            ($0["file_path"] as? String).flatMap { URL(string: "https://image.tmdb.org/t/p/w780\($0)") }
        }
        let simRaw = (obj["similar"] as? [String: Any])?["results"] as? [[String: Any]] ?? []
        let similar: [TMDBSimilarItem] = simRaw.prefix(12).compactMap { raw in
            guard let id = raw["id"] as? Int else { return nil }
            let t = (raw["title"] as? String) ?? (raw["name"] as? String) ?? ""
            let date = (raw["release_date"] as? String) ?? (raw["first_air_date"] as? String) ?? ""
            let y = date.count >= 4 ? Int(date.prefix(4)) : nil
            let poster = (raw["poster_path"] as? String)
                .flatMap { URL(string: "https://image.tmdb.org/t/p/w342\($0)") }
            return TMDBSimilarItem(id: id, title: t, year: y, posterURL: poster)
        }
        let runtime: Int? = mediaType == "movie"
            ? (obj["runtime"] as? Int)
            : ((obj["episode_run_time"] as? [Int])?.first)

        let details = TMDBDetails(
            overview: (obj["overview"] as? String) ?? "",
            genres: genreNames,
            rating: obj["vote_average"] as? Double,
            runtime: runtime,
            seasons: obj["number_of_seasons"] as? Int,
            tagline: (obj["tagline"] as? String) ?? "",
            cast: cast,
            crew: crew,
            stills: stills,
            similar: similar,
            tmdbID: tmdbID,
            mediaType: mediaType)
        lock.lock(); detailsCache[key] = details; lock.unlock()
        return details
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

// MARK: - 详情页元数据模型（v-detail：简介/演职人员/剧照/相似推荐/媒体信息）

struct TMDBPerson: Identifiable, Hashable {
    let id: Int
    let name: String
    let role: String        // 演员=角色名；工作人员=职务
    let profileURL: URL?
}

struct TMDBSimilarItem: Identifiable, Hashable {
    let id: Int
    let title: String
    let year: Int?
    let posterURL: URL?
}

struct TMDBDetails {
    let overview: String
    let genres: [String]
    let rating: Double?        // vote_average 0-10
    let runtime: Int?          // 电影片长（分钟）；剧集取单集时长
    let seasons: Int?          // 剧集季数
    let tagline: String
    let cast: [TMDBPerson]
    let crew: [TMDBPerson]
    let stills: [URL]
    let similar: [TMDBSimilarItem]
    let tmdbID: Int
    let mediaType: String      // movie / tv
}

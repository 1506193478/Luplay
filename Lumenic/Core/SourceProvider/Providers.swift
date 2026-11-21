import Foundation

enum ProviderError: Error {
    case notImplemented, notConfigured, badURL
    case badResponse(String)
}

// MARK: - 工厂（设置页编辑前测试连接 / AppEnvironment 重建实例）

enum ProviderFactory {
    static func make(_ config: ProviderConfig) -> SourceProvider {
        switch config.kind {
        case .emby: return EmbyProvider(config: config)
        case .alist: return AlistProvider(config: config)
        case .webdav: return WebDAVProvider(config: config)
        }
    }
}

// MARK: - 媒体信息推断（文件名 → 容器/分辨率/HDR/编码；探测不到时给保守值）

enum MediaProbe {
    static let videoExtensions: Set<String> = [
        "mp4", "mkv", "mov", "avi", "m4v", "ts", "webm", "wmv",
        "flv", "mpg", "mpeg", "m2ts", "rmvb", "vob",
    ]

    static func isVideoFile(_ name: String) -> Bool {
        videoExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    static func inferFilename(_ name: String) -> (container: String, resolution: String, hdr: String, codec: String?) {
        let base = name.lowercased()
        let ext = (name as NSString).pathExtension.lowercased()
        let container = videoExtensions.contains(ext) ? ext : "mp4"
        let resolution = base.contains("2160") || base.contains("4k") ? "4K"
            : base.contains("1080") ? "1080P"
            : base.contains("720") ? "720P" : "未知"
        let hdr = base.contains("dolby") || base.contains("dovi") ? "杜比视界"
            : base.contains("hdr") ? "HDR10" : "SDR"
        let codec = base.contains("hevc") || base.contains("h265") || base.contains("x265") ? "hevc"
            : (base.contains("avc") || base.contains("h264") || base.contains("x264") ? "avc" : nil)
        return (container, resolution, hdr, codec)
    }

    static func makeStreamInfo(url: URL, headers: [String: String], container: String,
                               codec: String?, resolution: String, hdr: String,
                               bitrateMbps: Double) -> StreamInfo {
        StreamInfo(url: url, headers: headers, container: container, codec: codec,
                   resolution: resolution, bitrateMbps: bitrateMbps, hdr: hdr,
                   recommendedEngine: EngineSelector.recommend(container: container, codec: codec, hdr: hdr))
    }
}

// MARK: - 集数解析（S01E14 / 第14集 / - 01.mp4）

enum EpisodeParser {
    static func guessNumber(from filename: String) -> Int? {
        let patterns = [
            "(?i)s\\d+[\\s._-]*e(\\d{1,4})\\b",
            "第\\s*(\\d{1,4})\\s*[集话話]",
            "(?i)[\\s._\\[-]ep?(\\d{1,4})[\\s._\\]-]",
            "(?i)[\\s._-](\\d{1,4})$",
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            let ns = filename as NSString
            if let m = re.firstMatch(in: filename, range: NSRange(location: 0, length: ns.length)),
               m.numberOfRanges > 1 {
                let g = m.range(at: 1)
                if g.location != NSNotFound, let n = Int(ns.substring(with: g)) { return n }
            }
        }
        return nil
    }
}

// MARK: - Emby / Jellyfin 片源

final class EmbyProvider: SourceProvider {
    var id: String { "emby:\(config.id)" }
    var displayName: String { config.displayName }

    private let config: ProviderConfig
    private var token: String?
    private var userID: String?
    private var userName: String?

    init(config: ProviderConfig) { self.config = config }

    var isConfigured: Bool {
        URL(string: config.serverURL.trimmingCharacters(in: .whitespaces)) != nil
            && !config.username.isEmpty
    }

    func testConnection() async throws -> String {
        try await authenticate()
        return "登录成功：\(userName ?? config.username)"
    }

    private var baseURL: URL? {
        var s = config.serverURL.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }

    /// POST /Users/AuthenticateByName → AccessToken（Emby/Jellyfin 通用）
    @discardableResult
    private func authenticate() async throws -> String {
        if let token { return token }
        guard let base = baseURL else { throw ProviderError.badURL }
        var req = URLRequest(url: base.appendingPathComponent("Users/AuthenticateByName"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("MediaBrowser Client=\"Luplay\", Device=\"iPhone\", DeviceId=\"luplay-ios\", Version=\"1.0\"",
                     forHTTPHeaderField: "X-Emby-Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject:
            ["Username": config.username, "Pw": config.password])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ProviderError.badResponse("无响应") }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.badResponse("登录失败 HTTP \(http.statusCode)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["AccessToken"] as? String else {
            throw ProviderError.badResponse("登录响应解析失败")
        }
        token = t
        let user = obj["User"] as? [String: Any]
        userID = user?["Id"] as? String
        userName = user?["Name"] as? String
        return t
    }

    private func get(_ path: String, query: [URLQueryItem]) async throws -> [String: Any] {
        guard let base = baseURL, var comps = URLComponents(url: base.appendingPathComponent(path),
                                                            resolvingAgainstBaseURL: false) else {
            throw ProviderError.badURL
        }
        comps.queryItems = query
        var req = URLRequest(url: comps.url!)
        req.setValue(token ?? "", forHTTPHeaderField: "X-Emby-Token")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProviderError.badResponse("请求失败 HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProviderError.badResponse("响应解析失败")
        }
        return obj
    }

    /// GET /Items?SearchTerm=…&Recursive=true
    func search(_ query: String) async throws -> [SourceItem] {
        try await authenticate()
        let obj = try await get("Items", query: [
            .init(name: "SearchTerm", value: query),
            .init(name: "IncludeItemTypes", value: "Movie,Series"),
            .init(name: "Recursive", value: "true"),
            .init(name: "Limit", value: "30"),
            .init(name: "Fields", value: "ProductionYear"),
        ])
        guard let items = obj["Items"] as? [[String: Any]] else { return [] }
        return items.compactMap { it in
            guard let itemId = it["Id"] as? String, let name = it["Name"] as? String else { return nil }
            let type = (it["Type"] as? String) == "Series" ? SourceItem.ItemType.series : .movie
            return SourceItem(id: itemId, providerId: id, title: name,
                              year: it["ProductionYear"] as? Int, type: type)
        }
    }

    /// 剧集：GET /Shows/{id}/Episodes；电影：单“集”伪条目
    func episodes(of item: SourceItem) async throws -> [Episode] {
        try await authenticate()
        if item.type == .movie {
            return [Episode(id: item.id, season: 1, episode: 1, title: item.title)]
        }
        var query: [URLQueryItem] = []
        if let userID { query.append(.init(name: "UserId", value: userID)) }
        let obj = try await get("Shows/\(item.id)/Episodes", query: query)
        guard let items = obj["Items"] as? [[String: Any]] else { return [] }
        return items.compactMap { it in
            guard let epId = it["Id"] as? String else { return nil }
            return Episode(id: epId,
                           season: it["ParentIndexNumber"] as? Int ?? 1,
                           episode: it["IndexNumber"] as? Int ?? 0,
                           title: it["Name"] as? String ?? "")
        }
    }

    /// GET /Items?Ids=&Fields=MediaSources → Static=true 直链 + 媒体信息
    func streamURL(of episode: Episode) async throws -> StreamInfo {
        try await authenticate()
        let obj = try await get("Items", query: [
            .init(name: "Ids", value: episode.id),
            .init(name: "Fields", value: "MediaSources"),
        ])
        guard let items = obj["Items"] as? [[String: Any]], let first = items.first,
              let sources = first["MediaSources"] as? [[String: Any]], let ms = sources.first else {
            throw ProviderError.badResponse("无可用媒体源")
        }

        let container = ((ms["Container"] as? String ?? "mp4")
            .components(separatedBy: ",").first ?? "mp4").lowercased()

        var codec: String?
        var resolution = "未知"
        var hdr = "SDR"
        var bitrateMbps = 0.0
        if let streams = ms["MediaStreams"] as? [[String: Any]],
           let video = streams.first(where: { ($0["Type"] as? String) == "Video" }) {
            codec = video["Codec"] as? String
            let w = video["Width"] as? Int ?? 0
            let h = video["Height"] as? Int ?? 0
            resolution = h >= 2000 || w >= 3600 ? "4K" : h >= 1000 ? "1080P" : h >= 600 ? "720P" : "未知"
            switch video["VideoRange"] as? String {
            case "DOVI", "Dolby Vision": hdr = "杜比视界"
            case "HDR10", "HLG": hdr = "HDR10"
            default: hdr = "SDR"
            }
            let br = (video["BitRate"] as? Double) ?? Double(video["BitRate"] as? Int ?? 0)
            bitrateMbps = br / 1_000_000
        }

        guard let base = baseURL,
              var comps = URLComponents(url: base.appendingPathComponent("Videos/\(episode.id)/stream.\(container)"),
                                        resolvingAgainstBaseURL: false) else {
            throw ProviderError.badURL
        }
        comps.queryItems = [.init(name: "Static", value: "true"),
                            .init(name: "api_key", value: token!)]
        guard let url = comps.url else { throw ProviderError.badURL }
        return MediaProbe.makeStreamInfo(url: url, headers: ["X-Emby-Token": token!],
                                         container: container, codec: codec,
                                         resolution: resolution, hdr: hdr, bitrateMbps: bitrateMbps)
    }
}

// MARK: - Alist 片源（115 / 阿里云盘聚合）

final class AlistProvider: SourceProvider {
    var id: String { "alist:\(config.id)" }
    var displayName: String { config.displayName }

    private let config: ProviderConfig
    private var token: String?

    init(config: ProviderConfig) { self.config = config }

    var isConfigured: Bool { baseURL != nil }

    func testConnection() async throws -> String {
        try await login()
        return "登录成功"
    }

    private var baseURL: URL? {
        var s = config.serverURL.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }

    private func request(path: String, body: [String: Any]) async throws -> [String: Any] {
        guard let base = baseURL, let url = URL(string: base.absoluteString + path) else {
            throw ProviderError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue(token, forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProviderError.badResponse("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.badResponse("响应解析失败")
        }
        guard (obj["code"] as? Int) == 200 else {
            throw ProviderError.badResponse(obj["message"] as? String ?? "接口异常")
        }
        return (obj["data"] as? [String: Any]) ?? [:]
    }

    /// POST /api/auth/login → token（Authorization 头）
    private func login() async throws {
        if token != nil { return }
        let data = try await request(path: "/api/auth/login",
                                     body: ["username": config.username, "password": config.password])
        guard let t = data["token"] as? String else { throw ProviderError.badResponse("登录失败") }
        token = t
    }

    /// POST /api/fs/search（限文件/目录命中）
    func search(_ query: String) async throws -> [SourceItem] {
        try await login()
        let data = try await request(path: "/api/fs/search",
                                     body: ["page": 1, "per_page": 50, "keywords": query, "parent": ""])
        guard let content = data["content"] as? [[String: Any]] else { return [] }
        return content.compactMap { c in
            let name = c["name"] as? String ?? ""
            let parent = c["parent"] as? String ?? ""
            let path = parent.hasSuffix("/") ? parent + name : parent + "/" + name
            let isDir = (c["is_dir"] as? Bool) ?? ((c["type"] as? Int) == 0)
            if isDir {
                return SourceItem(id: path, providerId: id, title: name, year: nil, type: .series)
            }
            guard MediaProbe.isVideoFile(name) else { return nil }
            return SourceItem(id: path, providerId: id, title: name, year: nil, type: .movie)
        }
    }

    /// 电影：单条目；目录：POST /api/fs/list 过滤视频文件
    func episodes(of item: SourceItem) async throws -> [Episode] {
        try await login()
        if item.type == .movie {
            return [Episode(id: item.id, season: 1, episode: 1, title: item.title)]
        }
        let data = try await request(path: "/api/fs/list",
                                     body: ["path": item.id, "page": 1, "per_page": 0, "refresh": false])
        guard let content = data["content"] as? [[String: Any]] else { return [] }
        let files = content
            .filter { !((($0["is_dir"] as? Bool) ?? (($0["type"] as? Int) == 0))) }
            .compactMap { $0["name"] as? String }
            .filter { MediaProbe.isVideoFile($0) }
        return files.enumerated().map { i, name in
            Episode(id: item.id + "/" + name, season: 1,
                    episode: EpisodeParser.guessNumber(from: name) ?? i + 1, title: name)
        }
    }

    /// POST /api/fs/get → raw_url（有时效，每次播放前重取）
    func streamURL(of episode: Episode) async throws -> StreamInfo {
        try await login()
        let data = try await request(path: "/api/fs/get", body: ["path": episode.id])
        var raw = data["raw_url"] as? String ?? ""
        if raw.isEmpty, let sign = data["sign"] as? String, !sign.isEmpty {
            raw = baseURL!.absoluteString + "/d" + episode.id + "?sign=" + sign
        }
        guard let url = URL(string: raw) else { throw ProviderError.badResponse("未取到播放直链") }
        let name = (episode.id as NSString).lastPathComponent
        let info = MediaProbe.inferFilename(name)
        return MediaProbe.makeStreamInfo(url: url, headers: [:], container: info.container,
                                         codec: info.codec, resolution: info.resolution,
                                         hdr: info.hdr, bitrateMbps: 0)
    }
}

// MARK: - WebDAV 片源（PROPFIND + Range 直链）

final class WebDAVProvider: SourceProvider {
    var id: String { "webdav:\(config.id)" }
    var displayName: String { config.displayName }

    private let config: ProviderConfig
    private let propfindBody = """
    <?xml version="1.0"?>
    <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>
    """

    init(config: ProviderConfig) { self.config = config }

    var isConfigured: Bool { baseURL != nil }

    func testConnection() async throws -> String {
        let entries = try await propfind(rootPath)
        return "连接成功，\(entries.count) 个条目"
    }

    struct WebDAVEntry { let path: String; let isDir: Bool; let size: Int64 }

    private var baseURL: URL? {
        var s = config.serverURL.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }

    private var rootPath: String {
        let p = config.rootPath.trimmingCharacters(in: .whitespaces)
        return p.isEmpty ? "/" : p
    }

    private var authHeaders: [String: String] {
        let cred = "\(config.username):\(config.password)"
        return ["Authorization": "Basic " + Data(cred.utf8).base64EncodedString()]
    }

    private func davURL(_ path: String) -> URL? {
        guard let base = baseURL else { return nil }
        let p = path.hasPrefix("/") ? path : "/" + path
        let raw = base.absoluteString + p
        if let u = URL(string: raw) { return u }
        let encoded = p.components(separatedBy: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
            .joined(separator: "/")
        return URL(string: base.absoluteString + encoded)
    }

    /// PROPFIND Depth:1 → multistatus XML 解析
    private func propfind(_ path: String) async throws -> [WebDAVEntry] {
        guard let url = davURL(path) else { throw ProviderError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "PROPFIND"
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        req.httpBody = propfindBody.data(using: .utf8)
        for (k, v) in authHeaders { req.setValue(v, forHTTPHeaderField: k) }

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, [200, 207].contains(http.statusCode) else {
            throw ProviderError.badResponse("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let parser = XMLParser(data: data)
        let delegate = PropfindParser()
        parser.delegate = delegate
        guard parser.parse() else { throw ProviderError.badResponse("目录解析失败") }
        return delegate.entries
    }

    /// BFS 目录搜索（限 3 层 / 30 条）
    func search(_ query: String) async throws -> [SourceItem] {
        let q = query.lowercased()
        var results: [SourceItem] = []
        var visited = 0
        var queue: [(path: String, depth: Int)] = [(rootPath, 0)]
        while let (dir, depth) = queue.popLast() {
            guard depth <= 2, visited < 40 else { continue }
            visited += 1
            let entries = (try? await propfind(dir)) ?? []
            for e in entries {
                let name = (e.path as NSString).lastPathComponent
                if e.isDir {
                    queue.insert((e.path, depth + 1), at: 0)
                } else if MediaProbe.isVideoFile(name), name.lowercased().contains(q) {
                    results.append(SourceItem(id: e.path, providerId: id, title: name,
                                              year: nil, type: .movie))
                }
            }
            if results.count >= 30 { break }
        }
        return results
    }

    func episodes(of item: SourceItem) async throws -> [Episode] {
        if item.type == .movie {
            return [Episode(id: item.id, season: 1, episode: 1, title: (item.id as NSString).lastPathComponent)]
        }
        let entries = try await propfind(item.id)
        let files = entries
            .filter { !$0.isDir }
            .map { (e.path as NSString).lastPathComponent }
            .filter { MediaProbe.isVideoFile($0) }
            .map { ($0, EpisodeParser.guessNumber(from: $0) ?? 0) }
            .sorted { $0.1 < $1.1 }
        return files.enumerated().map { i, f in
            let path = item.id.hasSuffix("/") ? item.id + f.0 : item.id + "/" + f.0
            return Episode(id: path, season: 1, episode: f.1 == 0 ? i + 1 : f.1, title: f.0)
        }
    }

    func streamURL(of episode: Episode) async throws -> StreamInfo {
        guard let url = davURL(episode.id) else { throw ProviderError.badURL }
        let name = (episode.id as NSString).lastPathComponent
        let info = MediaProbe.inferFilename(name)
        return MediaProbe.makeStreamInfo(url: url, headers: authHeaders, container: info.container,
                                         codec: info.codec, resolution: info.resolution,
                                         hdr: info.hdr, bitrateMbps: 0)
    }
}

/// multistatus XML 解析（命名空间前缀不定，按 localName 匹配）
private final class PropfindParser: NSObject, XMLParserDelegate {
    private(set) var entries: [WebDAVProvider.WebDAVEntry] = []
    private var text = ""
    private var href = ""
    private var isDir = false
    private var size: Int64 = 0

    private func localName(_ qName: String) -> String {
        qName.contains(":") ? String(qName.split(separator: ":").last!) : qName
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        switch localName(qName ?? elementName) {
        case "response": href = ""; isDir = false; size = 0
        case "collection": isDir = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        switch localName(qName ?? elementName) {
        case "href":
            href = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if href.hasSuffix("/") { isDir = true }
        case "getcontentlength":
            size = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        case "response":
            let path = href.removingPercentEncoding ?? href
            if !path.isEmpty {
                entries.append(WebDAVProvider.WebDAVEntry(path: path, isDir: isDir, size: size))
            }
        default: break
        }
    }
}

// MARK: - 本地文件（扫描沙盒 Documents）

final class LocalProvider: SourceProvider {
    let id = "local"
    let displayName = "本地文件"
    var isConfigured: Bool { true }

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func testConnection() async throws -> String {
        "本地库：\(scan().count) 个视频文件"
    }

    private func scan() -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: documentsURL, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.allObjects
            .compactMap { $0 as? URL }
            .filter { MediaProbe.isVideoFile($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func search(_ query: String) async throws -> [SourceItem] {
        scan()
            .filter { $0.lastPathComponent.localizedCaseInsensitiveContains(query) }
            .map { url in
                SourceItem(id: url.path, providerId: id, title: url.lastPathComponent,
                           year: nil, type: .movie)
            }
    }

    func episodes(of item: SourceItem) async throws -> [Episode] {
        [Episode(id: item.id, season: 1, episode: 1, title: (item.id as NSString).lastPathComponent)]
    }

    func streamURL(of episode: Episode) async throws -> StreamInfo {
        let url = URL(fileURLWithPath: episode.id)
        let info = MediaProbe.inferFilename((episode.id as NSString).lastPathComponent)
        return MediaProbe.makeStreamInfo(url: url, headers: [:], container: info.container,
                                         codec: info.codec, resolution: info.resolution,
                                         hdr: info.hdr, bitrateMbps: 0)
    }
}

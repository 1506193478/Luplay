import Foundation
import CryptoKit

// MARK: - 弹幕数据模型

struct DanmakuComment: Identifiable, Hashable {
    enum Mode: Int { case scroll = 1, bottom = 4, top = 5 }

    let id: String
    let time: Double
    let mode: Mode
    let color: UInt32
    let text: String

    /// 弹弹play p 字段解析："时间,模式,颜色,[来源]"
    static func parse(p: String, text: String, id: String) -> DanmakuComment? {
        let parts = p.components(separatedBy: ",")
        guard let t = Double(parts.first ?? "") else { return nil }
        let rawMode = Int(parts.count > 1 ? parts[1] : "1") ?? 1
        let mode: Mode
        switch rawMode {
        case 4: mode = .bottom
        case 5: mode = .top
        default: mode = .scroll      // 1/2/3/6/7 均按滚动处理
        }
        let color = UInt32(parts.count > 2 ? parts[2] : "16777215") ?? 0xFFFFFF
        return DanmakuComment(id: id.isEmpty ? UUID().uuidString : id,
                              time: t, mode: mode, color: color, text: text)
    }
}

// MARK: - 弹弹play 搜索结果

struct DandanAnime: Identifiable {
    let id: String
    let title: String
    let episodes: [DandanEpisode]
}

struct DandanEpisode: Identifiable, Hashable {
    let episodeId: Int
    let title: String
}

// MARK: - 弹弹play API 客户端（签名算法：base64(sha256(AppId + Timestamp + Path + AppSecret))）

/// 弹弹play 密钥：Keychain 存储，设置页可改；首启用种子值（应用审核中，403 时落演示弹幕）
enum DandanplayConfig {
    private static let appIdKey = "com.luplay.dandanplay.appId"
    private static let secretKey = "com.luplay.dandanplay.appSecret"
    private static let seedAppId = "dvapv5rxav"
    private static let seedSecret = "ZI45YwsgEpuQ8CajkIjiJGPVkNfyFTpY"

    /// 惰性种子：Keychain 无值时写入默认凭证（仅首启一次）
    private static func ensureSeeded() {
        if KeychainStore.shared.string(for: appIdKey) == nil {
            KeychainStore.shared.setString(seedAppId, for: appIdKey)
        }
        if KeychainStore.shared.string(for: secretKey) == nil {
            KeychainStore.shared.setString(seedSecret, for: secretKey)
        }
    }

    static var appId: String {
        ensureSeeded()
        return KeychainStore.shared.string(for: appIdKey) ?? ""
    }
    static var appSecret: String {
        ensureSeeded()
        return KeychainStore.shared.string(for: secretKey) ?? ""
    }
    static var isConfigured: Bool { !appId.isEmpty && !appSecret.isEmpty }

    static func save(appId: String, secret: String) {
        KeychainStore.shared.setString(appId, for: appIdKey)
        KeychainStore.shared.setString(secret, for: secretKey)
    }
}

final class DandanplayClient {
    private let baseURL = "https://api.dandanplay.net/api/v2"

    enum DanmakuError: Error, CustomStringConvertible {
        case notConfigured, badURL, badResponse(String)
        var description: String {
            switch self {
            case .notConfigured: return "未配置 AppId"
            case .badURL: return "URL 无效"
            case .badResponse(let m): return m
            }
        }
    }

    // MARK: 自动匹配

    /// 按标题+集号匹配弹幕库 → 返回最佳命中的 (作品, 集)
    /// GET /match 请求体 fileName 建议带扩展名；fileHash 为空时按标题匹配
    func match(title: String, episodeNumber: Int) async throws -> (DandanAnime, DandanEpisode)? {
        let fileName = episodeNumber > 0
            ? "\(title) 第\(episodeNumber)集.mp4"
            : "\(title).mp4"
        let body: [String: Any] = ["fileName": fileName, "fileHash": "", "fileSize": 0]
        let obj = try await signedRequest(path: "/match", method: "POST", body: body)
        guard let animes = obj["matchedAnimes"] as? [[String: Any]], !animes.isEmpty else { return nil }
        let anime = animes[0]
        guard let animeTitle = anime["animeTitle"] as? String,
              let eps = anime["episodes"] as? [[String: Any]], !eps.isEmpty else { return nil }
        let episodes = eps.compactMap { e -> DandanEpisode? in
            guard let epId = (e["episodeId"] as? Int) ?? Int(e["episodeId"] as? String ?? "") else { return nil }
            return DandanEpisode(episodeId: epId, title: e["episodeTitle"] as? String ?? "")
        }
        guard !episodes.isEmpty else { return nil }
        // 集号精确优先："第14话/集" 命中
        let picked = episodeNumber > 0
            ? (episodes.first { $0.title.contains("第\(episodeNumber)") }
               ?? episodes.first { $0.title.contains("\(episodeNumber)") })
            : nil
        return (DandanAnime(id: anime["animeId"] as? String ?? animeTitle,
                            title: animeTitle, episodes: episodes),
                picked ?? episodes[0])
    }

    /// 关键词搜索作品 + 集列表（手动换绑）
    func searchEpisodes(keyword: String) async throws -> [DandanAnime] {
        let obj = try await signedRequest(path: "/search/episodes", method: "POST",
                                          body: ["anime": keyword])
        guard let animes = obj["animes"] as? [[String: Any]] else { return [] }
        return animes.compactMap { a in
            guard let title = a["animeTitle"] as? String else { return nil }
            let eps = ((a["episodes"] as? [[String: Any]]) ?? []).compactMap { e -> DandanEpisode? in
                guard let epId = (e["episodeId"] as? Int) ?? Int(e["episodeId"] as? String ?? "") else { return nil }
                return DandanEpisode(episodeId: epId, title: e["episodeTitle"] as? String ?? "")
            }
            return DandanAnime(id: a["animeId"] as? String ?? title, title: title, episodes: eps)
        }
    }

    /// 拉取某集全部弹幕
    func comments(episodeId: Int) async throws -> [DanmakuComment] {
        let obj = try await signedRequest(path: "/comment/\(episodeId)?withRelated=true&chConvert=1",
                                          method: "GET", body: nil)
        guard let list = obj["comments"] as? [[String: Any]] else { return [] }
        return list.compactMap { c in
            guard let p = c["p"] as? String, let m = c["m"] as? String else { return nil }
            let cid = (c["cid"] as? Int).map(String.init) ?? (c["cid"] as? String) ?? ""
            return DanmakuComment.parse(p: p, text: m, id: cid)
        }
        .sorted { $0.time < $1.time }
    }

    // MARK: 签名请求
    // 官方算法：base64(sha256(AppId + Timestamp + Path + AppSecret))
    // 请求头 X-AppId / X-Signature（timestamp;signature）/ X-Timestamp

    private func signedRequest(path: String, method: String, body: [String: Any]?) async throws -> [String: Any] {
        guard DandanplayConfig.isConfigured else { throw DanmakuError.notConfigured }
        guard let url = URL(string: baseURL + path) else { throw DanmakuError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }

        let timestamp = String(Int(Date().timeIntervalSince1970))
        let data = (DandanplayConfig.appId + timestamp + path + DandanplayConfig.appSecret).utf8
        let digest = SHA256.hash(data: Data(data))
        let signature = Data(digest).base64EncodedString()
        request.setValue(DandanplayConfig.appId, forHTTPHeaderField: "X-AppId")
        request.setValue(timestamp + ";" + signature, forHTTPHeaderField: "X-Signature")
        request.setValue(timestamp, forHTTPHeaderField: "X-Timestamp")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DanmakuError.badResponse("无响应") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 403 {
                throw DanmakuError.badResponse("应用审核中（HTTP 403），暂用演示弹幕")
            }
            throw DanmakuError.badResponse("HTTP \(http.statusCode)")
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

// MARK: - B站 XML 导入解析器
// <d p="time,mode,size,color,date,pool,uid,rowid">文本</d>

enum DanmakuImporter {
    static func parseBilibiliXML(_ data: Data) -> [DanmakuComment] {
        let xml = String(data: data, encoding: .utf8) ?? ""
        var result: [DanmakuComment] = []
        for chunk in xml.components(separatedBy: "<d ") where chunk.contains("</d>") {
            guard let pRange = chunk.range(of: "p=\""),
                  let pEnd = chunk[pRange.upperBound...].range(of: "\""),
                  let mRange = chunk.range(of: "\">"),
                  let mEnd = chunk[mRange.upperBound...].range(of: "</d>")
            else { continue }
            let attrs = String(chunk[pRange.upperBound..<pEnd.lowerBound])
            let text = String(chunk[mRange.upperBound..<mEnd.lowerBound])
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let c = DanmakuComment.parse(p: attrs, text: text, id: "") else { continue }
            result.append(c)
        }
        return result.sorted { $0.time < $1.time }
    }
}

// MARK: - 演示弹幕（弹弹play 审核通过前的可玩性兜底）

enum MockDanmaku {
    private static let texts = [
        "前方高能", "名场面预定", "这画质太顶了", "4K 就是香", "弹幕护体",
        "导演镜头感绝了", "BGM 一响 泪目", "这段建议反复观看", "来了来了", "前排围观",
        "这排面我服", "画质党狂喜", "杜比视界没白等", "双内核切换丝滑", "进度条不敢拖",
        "看完直接收藏", "男主稳住", "女主好飒", "三集定律生效中", "结局别刀我",
    ]

    static func generate(duration: Double) -> [DanmakuComment] {
        var result: [DanmakuComment] = []
        let colors: [UInt32] = [0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFF6347, 0x66CCFF, 0xFFD700]
        var t: Double = 2
        var i = 0
        while t < max(30, duration - 5) {
            let mode: DanmakuComment.Mode = (i % 9 == 0) ? .top : (i % 17 == 0) ? .bottom : .scroll
            result.append(DanmakuComment(id: "mock-\(i)",
                                         time: (t * 100).rounded() / 100,
                                         mode: mode,
                                         color: colors[i % colors.count],
                                         text: texts[i % texts.count]))
            t += 0.55 + Double((i * 37) % 13) / 12.0   // 伪随机间隔
            i += 1
        }
        return result
    }
}

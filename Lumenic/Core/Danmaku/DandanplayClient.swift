import Foundation
import CryptoKit

// MARK: - 弹弹play API 客户端（自动匹配弹幕）

/// 申请步骤（拿到后填入下方 config 或设置页）：
/// 1. 访问 api.dandanplay.net 开放平台，注册账号并实名/邮箱验证
/// 2. 创建应用，获得 AppId 与 AppSecret
/// 3. 填入 DandanplayConfig.appId / .appSecret（生产环境存 Keychain）
struct DandanplayConfig {
    /// TODO(M4): 迁移至 Keychain + 设置页录入
    static var appId: String = "dvapv5rxav"
    static var appSecret: String = "ZI45YwsgEpuQ8CajkIjiJGPVkNfyFTpY"
    static var isConfigured: Bool { !appId.isEmpty && !appSecret.isEmpty }
}

struct DanmakuMatchResult: Identifiable {
    let id: String
    let animeTitle: String
    let episodeTitle: String
    let episodeId: Int
}

final class DandanplayClient {
    private let baseURL = "https://api.dandanplay.net/api/v2"

    /// 按标题+集数匹配弹幕库
    func match(title: String, episode: Int) async throws -> DanmakuMatchResult? {
        guard DandanplayConfig.isConfigured else { throw DanmakuError.notConfigured }
        let body: [String: Any] = ["fileName": "\(title) 第\(episode)集", "fileHash": "", "fileSize": 0]
        let (_, resp) = try await signedRequest(path: "/match", method: "POST", body: try JSONSerialization.data(withJSONObject: body))
        // 解析 matchedAnimes → episodes[0].episodeId（M5 完整解析）
        _ = resp
        return nil
    }

    /// 拉取某集弹幕（comments: [p, m]，p="时间,模式,颜色,来源"）
    func comments(episodeId: Int) async throws -> [(time: Double, text: String)] {
        guard DandanplayConfig.isConfigured else { throw DanmakuError.notConfigured }
        let (_, _) = try await signedRequest(path: "/comment/\(episodeId)", method: "GET", body: nil)
        return []
    }

    // MARK: - 签名（官方算法：base64(sha256(AppId + Timestamp + Path + AppSecret))，
    // 请求头需同时带 X-AppId / X-Signature / X-Timestamp）

    private func signedRequest(path: String, method: String, body: Data?) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: baseURL + path) else { throw DanmakuError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let timestamp = String(Int(Date().timeIntervalSince1970))
        let data = (DandanplayConfig.appId + timestamp + path + DandanplayConfig.appSecret).utf8
        let digest = SHA256.hash(data: Data(data))
        let signature = Data(digest).base64EncodedString()

        request.setValue(DandanplayConfig.appId, forHTTPHeaderField: "X-AppId")
        request.setValue(timestamp + ";" + signature, forHTTPHeaderField: "X-Signature")
        request.setValue(timestamp, forHTTPHeaderField: "X-Timestamp")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DanmakuError.badResponse }
        return (data, http)
    }
}

enum DanmakuError: Error {
    case notConfigured, badURL, badResponse
}

// MARK: - B站 XML 导入解析器（M5：XMLParser 完整版）

enum DanmakuImporter {
    /// B站 XML：<d p="time,mode,size,color,date,pool,uid,rowid">文本</d>
    static func parseBilibiliXML(_ data: Data) -> [(time: Double, text: String)] {
        let xml = String(data: data, encoding: .utf8) ?? ""
        var result: [(Double, String)] = []
        for chunk in xml.components(separatedBy: "<d ") where chunk.contains("</d>") {
            guard let pRange = chunk.range(of: "p=\""),
                  let pEnd = chunk[pRange.upperBound...].range(of: "\""),
                  let mRange = chunk.range(of: "\">"),
                  let mEnd = chunk[mRange.upperBound...].range(of: "</d>")
            else { continue }
            let attrs = String(chunk[pRange.upperBound..<pEnd.lowerBound])
            let text = String(chunk[mRange.upperBound..<mEnd.lowerBound])
            if let t = Double(attrs.components(separatedBy: ",").first ?? "") {
                result.append((t, text))
            }
        }
        return result.sorted { $0.0 < $1.0 }
    }
}

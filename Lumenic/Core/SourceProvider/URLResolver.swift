import Foundation

// MARK: - 网络直链解析（粘贴 URL → HEAD/Range 探测 → StreamInfo）

enum URLResolverError: LocalizedError {
    case badURL
    case unreachable(String)
    case notMedia(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "链接格式无效，请检查后重试"
        case .unreachable(let detail): return "无法访问该链接：\(detail)"
        case .notMedia(let detail): return detail
        }
    }
}

enum URLResolver {

    /// 规范化输入：补协议头、校验 URL；返回 nil 表示格式无效
    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        return URL(string: s)
    }

    /// 从链接推断展示标题：文件名（去扩展名）优先，退化为主机名
    static func guessTitle(_ url: URL) -> String {
        let name = url.lastPathComponent.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, name != "/" {
            let base = (name as NSString).deletingPathExtension
            if !base.isEmpty { return base }
        }
        return url.host ?? "网络视频"
    }

    /// 探测直链媒体信息：HEAD 优先（部分服务器不支持 HEAD 时回退 Range GET），
    /// 扩展名优先、Content-Type 兜底推断容器；文件名推断分辨率/HDR/编码
    static func resolve(_ raw: String) async throws -> StreamInfo {
        guard let url = normalize(raw) else { throw URLResolverError.badURL }
        let probe = try await probe(url)

        // 网页响应说明不是媒体直链（常见的分享页/跳转页）
        let ct = probe.contentType.lowercased()
        if !probe.isSuccess || ct.contains("text/html") || ct.contains("application/xhtml") {
            throw URLResolverError.notMedia("该链接返回的是网页（HTTP \(probe.statusCode)），不是可播放的媒体直链")
        }

        let ext = url.pathExtension.lowercased()
        let container = inferContainer(ext: ext, contentType: probe.contentType)
        let filename = url.lastPathComponent.isEmpty ? "网络视频" : url.lastPathComponent
        let nameInfo = MediaProbe.inferFilename(filename)
        // 有体积但拿不到时长时码率置 0（未知），质量分不虚高
        return MediaProbe.makeStreamInfo(url: probe.finalURL, headers: [:],
                                         container: container, codec: nameInfo.codec,
                                         resolution: nameInfo.resolution, hdr: nameInfo.hdr,
                                         bitrateMbps: 0)
    }

    // MARK: - 探测

    struct ProbeResult {
        let isSuccess: Bool
        let statusCode: Int
        let contentType: String
        let contentLength: Int64
        let finalURL: URL
    }

    private static func probe(_ url: URL) async throws -> ProbeResult {
        // 先 HEAD：不下载任何数据
        if let result = await probeOnce(url, method: "HEAD") { return result }
        // HEAD 失败/被拒 → Range GET 只取 2 字节
        if let result = await probeOnce(url, method: "GET", range: "bytes=0-1") { return result }
        throw URLResolverError.unreachable("连接失败或超时")
    }

    /// 单次探测：nil 表示请求层失败（网络错误），由上层决定回退策略
    private static func probeOnce(_ url: URL, method: String, range: String? = nil) async -> ProbeResult? {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 12
        if let range { req.setValue(range, forHTTPHeaderField: "Range") }
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return nil }
            let length = http.expectedContentLength >= 0 ? http.expectedContentLength : 0
            return ProbeResult(isSuccess: (200..<300).contains(http.statusCode),
                               statusCode: http.statusCode,
                               contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "",
                               contentLength: length,
                               finalURL: http.url ?? url)
        } catch {
            return nil
        }
    }

    /// 容器推断：视频扩展名直接采信，否则按 Content-Type 映射，兜底扩展名/mp4
    private static func inferContainer(ext: String, contentType: String) -> String {
        if MediaProbe.videoExtensions.contains(ext) || ext == "m3u8" { return ext }
        let ct = contentType.lowercased()
        if ct.contains("mpegurl") || ct.contains("m3u8") { return "m3u8" }
        if ct.contains("matroska") { return "mkv" }
        if ct.contains("mp2t") { return "ts" }
        if ct.contains("flv") { return "flv" }
        if ct.contains("quicktime") { return "mov" }
        if ct.contains("webm") { return "webm" }
        if ct.contains("avi") { return "avi" }
        if ct.contains("mp4") || ct.contains("octet-stream") { return ext.isEmpty ? "mp4" : ext }
        return ext.isEmpty ? "mp4" : ext
    }
}

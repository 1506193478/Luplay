import Foundation

enum ProviderError: Error { case notImplemented, notConfigured }

// MARK: - Emby / Jellyfin 片源

final class EmbyProvider: SourceProvider {
    let id = "emby"
    let displayName = "Emby / Jellyfin"
    /// M4：从设置/Keychain 读取服务器地址、用户名、密码 → /Users/AuthenticateByName 换 AccessToken
    var isConfigured: Bool { false }

    func search(_ query: String) async throws -> [SourceItem] {
        // GET /Items?SearchTerm=&api_key=...（含远程检索）
        []
    }
    func episodes(of item: SourceItem) async throws -> [Episode] {
        // GET /Shows/{id}/Episodes
        []
    }
    func streamURL(of episode: Episode) async throws -> StreamInfo {
        // GET /Videos/{id}/stream.{container}?Static=true → 直接播放；.Transcoding=true → HLS
        throw ProviderError.notImplemented // M4 实现
    }
}

// MARK: - Alist 片源（115 / 阿里云盘聚合）

final class AlistProvider: SourceProvider {
    let id = "alist"
    let displayName = "Alist"
    var isConfigured: Bool { false }

    func search(_ query: String) async throws -> [SourceItem] { [] }        // POST /api/fs/search
    func episodes(of item: SourceItem) async throws -> [Episode] { [] }     // POST /api/fs/list
    func streamURL(of episode: Episode) async throws -> StreamInfo {
        // POST /api/fs/get → raw_url（有时效，换源/续播前必须重取）
        throw ProviderError.notImplemented // M4 实现
    }
}

// MARK: - WebDAV 片源

final class WebDAVProvider: SourceProvider {
    let id = "webdav"
    let displayName = "WebDAV"
    var isConfigured: Bool { false }

    func search(_ query: String) async throws -> [SourceItem] { [] }
    func episodes(of item: SourceItem) async throws -> [Episode] { [] }
    func streamURL(of episode: Episode) async throws -> StreamInfo {
        // PROPFIND 遍历 → 直链 GET（Range 边下边播）；BasicAuth 进 headers
        throw ProviderError.notImplemented // M4 实现
    }
}

// MARK: - 本地文件

final class LocalProvider: SourceProvider {
    let id = "local"
    let displayName = "本地文件"
    var isConfigured: Bool { true }

    func search(_ query: String) async throws -> [SourceItem] { [] }        // M4：扫描沙盒 Documents
    func episodes(of item: SourceItem) async throws -> [Episode] { [] }
    func streamURL(of episode: Episode) async throws -> StreamInfo {
        throw ProviderError.notImplemented // M4 实现
    }
}

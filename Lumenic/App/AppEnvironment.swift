import SwiftUI

/// 全局依赖容器：片源注册表、数据库、播放会话
@MainActor
final class AppEnvironment: ObservableObject {
    let providers: [SourceProvider]
    let database: AppDatabase
    let tmdb = TMDBService()
    let dandanplay = DandanplayClient()
    let cast = CastService()

    init() {
        self.providers = [
            EmbyProvider(),
            AlistProvider(),
            WebDAVProvider(),
            LocalProvider(),
        ]
        self.database = (try? AppDatabase()) ?? .inMemory
    }
}

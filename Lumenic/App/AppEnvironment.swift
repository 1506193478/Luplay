import SwiftUI

/// 全局依赖容器：片源注册表、数据库、播放会话
@MainActor
final class AppEnvironment: ObservableObject {
    /// 已配置的片源实例（设置页变更后 rebuildProviders 重建）
    @Published private(set) var providers: [SourceProvider] = []
    let providerStore = ProviderStore()
    let database: AppDatabase
    let tmdb = TMDBService()
    let aggregator: SearchAggregator
    let dandanplay = DandanplayClient()
    let cast = CastService()
    let cloudSync = CloudSyncService()

    init() {
        self.database = (try? AppDatabase()) ?? .inMemory
        self.aggregator = SearchAggregator(tmdb: tmdb)
        rebuildProviders()
        cloudSync.configure(database: database)   // iCloud 同步（开关在设置页）
    }

    func rebuildProviders() {
        var list = providerStore.configs.map(ProviderFactory.make)
        list.append(LocalProvider())
        providers = list
    }

    func upsertProvider(_ config: ProviderConfig) {
        providerStore.upsert(config)
        rebuildProviders()
    }

    func removeProvider(_ id: String) {
        providerStore.remove(id)
        rebuildProviders()
    }
}

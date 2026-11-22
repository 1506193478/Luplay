import Foundation
import CloudKit
import CryptoKit

/// 本地数据变更通知（AppDatabase 各 save 发出；CloudSyncService 去抖后自动同步）
extension Notification.Name {
    static let luplayDataChanged = Notification.Name("luplay.dataChanged")
}

/// iCloud 云同步（CloudKit 手动 CKRecord 同步，不上 Core Data、不动 SQLite 表结构）：
/// 三类记录 — 播放进度(progress) / 媒体库收藏(library) / 片头片尾弹幕设置(skipMarker)。
/// recordName 用 key 的 SHA256（规避中文/冒号等字符限制），完整 key 存于 "key" 字段。
/// 合并策略：进度按 updatedAt 新者胜；收藏按 addedAt 新者胜；跳过标记无时间戳，
/// 远端有本地缺才补插、本地始终覆盖远端（最后写入者胜出）。
/// 注意：真机分发需在开发者账号开启 iCloud capability（CI 模拟器构建不受影响）。
@MainActor
final class CloudSyncService: ObservableObject {
    static let enabledKey = "cloudkit.sync.enabled"

    @Published private(set) var accountAvailable = false
    @Published private(set) var syncing = false
    @Published private(set) var statusText = "未开启"
    @Published var enabled = UserDefaults.standard.bool(forKey: CloudSyncService.enabledKey) {
        didSet {
            UserDefaults.standard.set(enabled, forKey: CloudSyncService.enabledKey)
            if enabled {
                statusText = "检查中…"
                Task { await refreshAccount(); await syncNow() }
            } else {
                statusText = "未开启"
            }
        }
    }

    /// iCloud 容器按需创建：未签名安装（侧载无 iCloud entitlement）时
    /// CKContainer.default() 会直接抛 NSException 闪退，必须等用户开启同步后才触碰
    private var container: CKContainer?
    private func ensureContainer() -> CKContainer? {
        guard enabled else { return nil }
        if container == nil { container = CKContainer.default() }
        return container
    }
    private var database: AppDatabase?
    private var debounceTask: Task<Void, Never>?
    private var dataChangeObserver: NSObjectProtocol?   // 通知令牌，deinit 移除

    init() {
        // 本地数据变更（关播放器存进度/收藏/跳过标记）→ 2.5s 去抖自动同步
        // （同步过程中的拉取回写不触发，避免自激循环）
        dataChangeObserver = NotificationCenter.default.addObserver(
            forName: .luplayDataChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.enabled, self.accountAvailable, !self.syncing else { return }
                self.debounceTask?.cancel()
                self.debounceTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    guard !Task.isCancelled else { return }
                    await self?.syncNow()
                }
            }
        }
    }

    deinit {
        if let dataChangeObserver {
            NotificationCenter.default.removeObserver(dataChangeObserver)
        }
        debounceTask?.cancel()
    }

    func configure(database: AppDatabase) {
        self.database = database
        Task {
            await refreshAccount()
            if enabled, accountAvailable { await syncNow() }
        }
    }

    private var privateDB: CKDatabase? { container?.privateCloudDatabase }

    func refreshAccount() async {
        guard let container = ensureContainer() else {
            accountAvailable = false
            statusText = "未开启"
            return
        }
        let status = (try? await container.accountStatus()) ?? .couldNotDetermine
        accountAvailable = status == .available
        guard enabled else { return }
        switch status {
        case .available:
            if statusText == "检查中…" || statusText == "未开启" { statusText = "已就绪" }
        case .noAccount: statusText = "未登录 iCloud"
        case .temporarilyUnavailable: statusText = "iCloud 暂不可用"
        case .restricted, .couldNotDetermine: statusText = "iCloud 不可用"
        @unknown default: statusText = "iCloud 不可用"
        }
    }

    func syncNow() async {
        guard enabled, accountAvailable, !syncing, let db = database else { return }
        syncing = true
        defer { syncing = false }
        do {
            try await pullAndMerge(db)
            try await pushAll(db)
            statusText = "最近同步 " + DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        } catch {
            statusText = "同步失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 拉取合并

    private func pullAndMerge(_ db: AppDatabase) async throws {
        // 播放进度：updatedAt 新者胜
        for rec in try await fetchAll("progress") {
            guard let key = rec["key"] as? String,
                  let remoteDate = rec["updatedAt"] as? Date else { continue }
            let remote = PlaybackProgress(
                tmdbKey: key,
                season: (rec["season"] as? Int) ?? 1,
                episode: (rec["episode"] as? Int) ?? 1,
                position: (rec["position"] as? Double) ?? 0,
                duration: (rec["duration"] as? Double) ?? 0,
                updatedAt: remoteDate
            )
            let local = try? db.progress(forKey: key)
            if local == nil || (local!.updatedAt < remoteDate) {
                try? db.save(progress: remote)
            }
        }

        // 媒体库收藏：addedAt 新者胜
        for rec in try await fetchAll("library") {
            guard let key = rec["key"] as? String,
                  let addedAt = rec["addedAt"] as? Date else { continue }
            let remote = LibraryEntry(
                tmdbKey: key,
                title: (rec["title"] as? String) ?? key,
                providerIds: (rec["providerIds"] as? [String]) ?? [],
                posterPath: rec["posterPath"] as? String,
                addedAt: addedAt
            )
            let local = try? db.libraryEntry(forKey: key)
            if local == nil || (local!.addedAt < addedAt) {
                try? db.save(libraryEntry: remote)
            }
        }

        // 片头片尾弹幕设置：本地缺失才补插（远端覆盖本地空位）
        for rec in try await fetchAll("skipMarker") {
            guard let key = rec["key"] as? String else { continue }
            if (try? db.skipMarker(forKey: key)) == nil {
                try? db.save(skipMarker: SkipMarker(
                    mediaKey: key,
                    introStart: rec["introStart"] as? Double,
                    introEnd: rec["introEnd"] as? Double,
                    outroStart: rec["outroStart"] as? Double,
                    autoSkip: (rec["autoSkip"] as? Bool) ?? false
                ))
            }
        }
    }

    // MARK: - 推送

    private func pushAll(_ db: AppDatabase) async throws {
        var records: [CKRecord] = []
        records += (try? db.allProgress())?.map(progressRecord) ?? []
        records += (try? db.allLibraryEntries())?.map(libraryRecord) ?? []
        records += (try? db.allSkipMarkers())?.map(skipMarkerRecord) ?? []
        guard !records.isEmpty else { return }
        guard let privateDB else { return }
        _ = try await privateDB.modifyRecords(saving: records, deleting: [], savePolicy: .allKeys)
    }

    // MARK: - CKRecord 映射

    private func progressRecord(_ p: PlaybackProgress) -> CKRecord {
        let rec = CKRecord(recordType: "progress", recordID: .init(recordName: "p-" + Self.recordName(p.tmdbKey)))
        rec["key"] = p.tmdbKey
        rec["season"] = p.season
        rec["episode"] = p.episode
        rec["position"] = p.position
        rec["duration"] = p.duration
        rec["updatedAt"] = p.updatedAt
        return rec
    }

    private func libraryRecord(_ e: LibraryEntry) -> CKRecord {
        let rec = CKRecord(recordType: "library", recordID: .init(recordName: "l-" + Self.recordName(e.tmdbKey)))
        rec["key"] = e.tmdbKey
        rec["title"] = e.title
        rec["providerIds"] = e.providerIds
        rec["posterPath"] = e.posterPath
        rec["addedAt"] = e.addedAt
        return rec
    }

    private func skipMarkerRecord(_ m: SkipMarker) -> CKRecord {
        let rec = CKRecord(recordType: "skipMarker", recordID: .init(recordName: "s-" + Self.recordName(m.mediaKey)))
        rec["key"] = m.mediaKey
        rec["introStart"] = m.introStart
        rec["introEnd"] = m.introEnd
        rec["outroStart"] = m.outroStart
        rec["autoSkip"] = m.autoSkip
        return rec
    }

    /// key → SHA256 十六进制（CKRecord recordName 规避非法字符；上限远小于 255）
    private static func recordName(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 查询（数据量小，单次 500 条足够；>500 时超出部分忽略）

    private func fetchAll(_ type: String) async throws -> [CKRecord] {
        try await withCheckedThrowingContinuation { cont in
            let op = CKQueryOperation(query: CKQuery(recordType: type, predicate: NSPredicate(value: true)))
            op.resultsLimit = 500
            var acc: [CKRecord] = []
            op.recordMatchedBlock = { _, result in
                if let rec = try? result.get() { acc.append(rec) }
            }
            op.queryResultBlock = { result in
                switch result {
                case .success: cont.resume(returning: acc)
                case .failure(let e): cont.resume(throwing: e)
                }
            }
            guard let privateDB else { cont.resume(returning: []); return }
            privateDB.add(op)
        }
    }
}

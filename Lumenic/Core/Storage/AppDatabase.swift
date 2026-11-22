import Foundation
import GRDB

// MARK: - 数据层（GRDB/SQLite；SwiftData 需 iOS 17 故不采用，方案 §8）

struct PlaybackProgress: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "playback_progress"
    var tmdbKey: String        // tmdb:12345 或标题归一化 key
    var season: Int
    var episode: Int
    var position: Double
    var duration: Double
    var updatedAt: Date
}

struct LibraryEntry: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "library_entries"
    var tmdbKey: String
    var title: String
    var providerIds: [String]  // 命中的片源
    var posterPath: String?
    var addedAt: Date
}

/// 片头片尾标记（M6）：按媒体 key 记录跳过区间与自动跳过开关
struct SkipMarker: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "skip_markers"
    var mediaKey: String
    var introStart: Double?
    var introEnd: Double?
    var outroStart: Double?
    var autoSkip: Bool
}

final class AppDatabase {
    let dbWriter: any DatabaseWriter

    init() throws {
        let path = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("luplay.sqlite")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        dbWriter = try DatabaseQueue(path: path.path)
        try migrator.migrate(dbWriter)
    }

    /// 预览/测试用内存库（内存队列与迁移不可能失败）
    static var inMemory: AppDatabase { try! AppDatabase(makeWriter: { try! DatabaseQueue() }) }

    private init(makeWriter: () throws -> any DatabaseWriter) throws {
        dbWriter = try makeWriter()
        try migrator.migrate(dbWriter)
    }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "playback_progress") { t in
                t.primaryKey("tmdbKey", .text)
                t.column("season", .integer).notNull().defaults(to: 1)
                t.column("episode", .integer).notNull().defaults(to: 1)
                t.column("position", .double).notNull().defaults(to: 0)
                t.column("duration", .double).notNull().defaults(to: 0)
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "library_entries") { t in
                t.primaryKey("tmdbKey", .text)
                t.column("title", .text).notNull()
                t.column("providerIds", .jsonText).notNull().defaults(to: "[]")
                t.column("posterPath", .text)
                t.column("addedAt", .datetime).notNull()
            }
        }
        m.registerMigration("v2") { db in
            try db.create(table: "skip_markers") { t in
                t.primaryKey("mediaKey", .text)
                t.column("introStart", .double)
                t.column("introEnd", .double)
                t.column("outroStart", .double)
                t.column("autoSkip", .boolean).notNull().defaults(to: true)
            }
        }
        return m
    }

    // MARK: 进度

    func save(progress: PlaybackProgress) throws {
        try dbWriter.write { db in
            try progress.save(db)
        }
        notifyChanged()
    }

    func progress(forKey key: String) throws -> PlaybackProgress? {
        try dbWriter.read { db in
            try PlaybackProgress.filter(Column("tmdbKey") == key).fetchOne(db)
        }
    }

    // MARK: 片头片尾标记

    func save(skipMarker: SkipMarker) throws {
        try dbWriter.write { db in
            try skipMarker.save(db)
        }
        notifyChanged()
    }

    func skipMarker(forKey key: String) throws -> SkipMarker? {
        try dbWriter.read { db in
            try SkipMarker.filter(Column("mediaKey") == key).fetchOne(db)
        }
    }

    /// 全部播放进度（首页继续观看 / 媒体库最近添加）
    func allProgress() throws -> [PlaybackProgress] {
        try dbWriter.read { db in
            try PlaybackProgress.order(Column("updatedAt").desc).fetchAll(db)
        }
    }

    /// 全部片头片尾标记（云同步用）
    func allSkipMarkers() throws -> [SkipMarker] {
        try dbWriter.read { db in
            try SkipMarker.fetchAll(db)
        }
    }

    // MARK: 媒体库条目

    /// upsert 一条媒体库条目（primaryKey tmdbKey）
    func save(libraryEntry: LibraryEntry) throws {
        try dbWriter.write { db in
            try libraryEntry.save(db)
        }
        notifyChanged()
    }

    func libraryEntry(forKey key: String) throws -> LibraryEntry? {
        try dbWriter.read { db in
            try LibraryEntry.filter(Column("tmdbKey") == key).fetchOne(db)
        }
    }

    /// 全部媒体库条目（最近添加在前）
    func allLibraryEntries() throws -> [LibraryEntry] {
        try dbWriter.read { db in
            try LibraryEntry.order(Column("addedAt").desc).fetchAll(db)
        }
    }

    /// 本地数据落盘通知（CloudSyncService 去抖后自动同步）
    private func notifyChanged() {
        NotificationCenter.default.post(name: .luplayDataChanged, object: nil)
    }
}

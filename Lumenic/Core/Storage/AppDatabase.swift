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
        dbWriter = try DatabaseQueue(path: path.absoluteString)
        try migrator.migrate(dbWriter)
    }

    /// 预览/测试用内存库
    static var inMemory: AppDatabase { AppDatabase(makeWriter: { try! DatabaseQueue.inMemory() }) }

    private init(makeWriter: () throws -> any DatabaseWriter) {
        dbWriter = try! makeWriter()
        try! migrator.migrate(dbWriter)
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
    }

    func skipMarker(forKey key: String) throws -> SkipMarker? {
        try dbWriter.read { db in
            try SkipMarker.filter(Column("mediaKey") == key).fetchOne(db)
        }
    }
}

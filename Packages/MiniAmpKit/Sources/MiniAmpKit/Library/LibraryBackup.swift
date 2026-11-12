import Foundation
import GRDB

/// Backups of the library database and the app's settings, in one file.
///
/// A backup is an SQLite copy of the library (taken with SQLite's online backup, so it's
/// consistent even mid-scan) plus two tables of its own: what it is, and the settings as a
/// property list. Cover thumbnails aren't included; they're made again from the music files.
public enum LibraryBackup {
    public static let fileExtension = "miniampbackup"

    public struct Info: Sendable, Equatable {
        public var createdAt: Date
        public var appVersion: String
        public var tracks: Int
        public var playlists: Int
        public var plays: Int
    }

    public struct NotABackup: Error, CustomStringConvertible {
        public var description: String { "That file isn't a miniamp backup." }
    }

    public struct NewerBackup: Error, CustomStringConvertible {
        public var description: String { "That backup was made by a newer miniamp; update the app to restore it." }
    }

    /// Writes a backup of `database` with `settings` (property-list values) to `url`, replacing
    /// whatever is there only once the backup is complete.
    public static func write(_ database: AppDatabase, settings: [String: Any], appVersion: String, to url: URL) throws {
        let settingsData = try PropertyListSerialization.data(fromPropertyList: settings, format: .binary, options: 0)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("miniamp-backup-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let copy = try DatabaseQueue(path: temporary.path)
            try database.writer.backup(to: copy)
            try copy.write { db in
                try db.execute(sql: """
                    CREATE TABLE backupInfo (createdAt DATETIME NOT NULL, appVersion TEXT NOT NULL);
                    CREATE TABLE backupSettings (plist BLOB NOT NULL);
                    """)
                try db.execute(sql: "INSERT INTO backupInfo VALUES (?, ?)", arguments: [Date(), appVersion])
                try db.execute(sql: "INSERT INTO backupSettings VALUES (?)", arguments: [settingsData])
            }
            // The copy keeps the library's WAL mode; a single self-contained file is what's wanted.
            try copy.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode = DELETE") }
            try copy.vacuum()
            try copy.close()
        }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    /// What a backup holds, without restoring it.
    public static func info(of url: URL) throws -> Info {
        try withBackup(at: url) { db in try info(db) }
    }

    /// Replaces everything in `database` with the backup's contents, and returns the backup's
    /// settings for the caller to apply.
    ///
    /// The schema is brought up to date if the backup is older. Tracks whose cover thumbnail
    /// isn't in `artwork` are marked changed, so the next scan reads them again and remakes it.
    @discardableResult
    public static func restore(from url: URL, into database: AppDatabase, artwork: ArtworkCache?) throws -> [String: Any] {
        let settings = try withBackup(at: url) { db -> [String: Any] in
            _ = try info(db)
            let applied = try Set(String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"))
            let known = Set(AppDatabase.migrator.migrations)
            guard applied.isSubset(of: known) else { throw NewerBackup() }
            guard let data = try Data.fetchOne(db, sql: "SELECT plist FROM backupSettings") else { return [:] }
            return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
        }
        let source = try DatabaseQueue(path: url.path, configuration: readOnly)
        try source.backup(to: database.writer)
        try source.close()
        // The backup's journal mode came across with its pages; the library uses WAL.
        if database.writer is DatabasePool {
            try database.writer.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode = WAL") }
        }
        // The backup's own tables go before migrating: in debug builds the migrator erases a
        // database whose schema it doesn't recognise.
        try database.writer.write { try $0.execute(sql: "DROP TABLE backupInfo; DROP TABLE backupSettings") }
        try AppDatabase.migrator.migrate(database.writer)
        try database.writer.write { db in
            for row in try Row.fetchAll(db, sql: "SELECT id, artworkKey FROM track WHERE artworkKey IS NOT NULL") {
                let key: String = row["artworkKey"]
                if let artwork, FileManager.default.fileExists(atPath: artwork.thumbnailURL(for: key).path) { continue }
                try db.execute(sql: "UPDATE track SET modifiedAt = 0 WHERE id = ?", arguments: [row["id"] as Int64])
            }
        }
        return settings
    }

    private static var readOnly: Configuration {
        var configuration = Configuration()
        configuration.readonly = true
        return configuration
    }

    private static func withBackup<T>(at url: URL, _ body: (Database) throws -> T) throws -> T {
        let queue: DatabaseQueue
        do { queue = try DatabaseQueue(path: url.path, configuration: readOnly) } catch { throw NotABackup() }
        defer { try? queue.close() }
        return try queue.read { db in
            guard try db.tableExists("backupInfo"), try db.tableExists("backupSettings") else { throw NotABackup() }
            return try body(db)
        }
    }

    private static func info(_ db: Database) throws -> Info {
        guard let row = try Row.fetchOne(db, sql: "SELECT createdAt, appVersion FROM backupInfo") else { throw NotABackup() }
        return Info(createdAt: row["createdAt"], appVersion: row["appVersion"],
                    tracks: try Int.fetchOne(db, sql: "SELECT count(*) FROM track") ?? 0,
                    playlists: try Int.fetchOne(db, sql: "SELECT count(*) FROM playlist") ?? 0,
                    plays: try Int.fetchOne(db, sql: "SELECT count(*) FROM play") ?? 0)
    }
}

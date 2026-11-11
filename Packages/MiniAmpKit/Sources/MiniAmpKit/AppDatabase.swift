import Foundation
import GRDB

/// Owns the SQLite connection. The real schema lands in M3 (issue: database schema).
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    /// Opens (creating if needed) the database in Application Support.
    public static func onDisk(fileManager: FileManager = .default) throws -> AppDatabase {
        let dir = try fileManager
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("miniamp", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return try AppDatabase(DatabasePool(path: dir.appendingPathComponent("library.sqlite").path))
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        #if DEBUG
        m.eraseDatabaseOnSchemaChange = true
        #endif
        // Migrations are registered here starting in M3.
        return m
    }

    public var sqliteVersion: String {
        get throws { try writer.read { try String.fetchOne($0, sql: "SELECT sqlite_version()") ?? "?" } }
    }
}

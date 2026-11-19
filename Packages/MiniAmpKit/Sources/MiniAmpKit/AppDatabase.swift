import Foundation
import GRDB

/// Owns the SQLite connection and the schema (see Library/Schema.swift).
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    /// Opens (creating if needed) a database at `path`. WAL mode, so reads never wait on the scanner.
    public static func at(_ path: String) throws -> AppDatabase {
        try AppDatabase(DatabasePool(path: path))
    }

    /// Opens (creating if needed) the database in Application Support.
    public static func onDisk(fileManager: FileManager = .default) throws -> AppDatabase {
        let dir = try fileManager
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("miniamp", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return try at(dir.appendingPathComponent("library.sqlite").path)
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        #if DEBUG
        m.eraseDatabaseOnSchemaChange = true
        #endif
        m.registerMigration("v1", migrate: Schema.v1)
        m.registerMigration("v2", migrate: Schema.v2)
        m.registerMigration("v3", migrate: Schema.v3)
        m.registerMigration("v4", migrate: Schema.v4)
        m.registerMigration("v5", migrate: Schema.v5)
        m.registerMigration("v6", migrate: Schema.v6)
        m.registerMigration("v7", migrate: Schema.v7)
        m.registerMigration("v8", migrate: Schema.v8)
        m.registerMigration("v9", migrate: Schema.v9)
        m.registerMigration("v10", migrate: Schema.v10)
        m.registerMigration("v11", migrate: Schema.v11)
        return m
    }

    public var sqliteVersion: String {
        get throws { try writer.read { try String.fetchOne($0, sql: "SELECT sqlite_version()") ?? "?" } }
    }
}

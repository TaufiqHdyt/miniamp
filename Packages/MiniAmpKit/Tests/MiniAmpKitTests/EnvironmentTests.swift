import Foundation
import GRDB
import Testing
@testable import MiniAmpKit

@Suite struct EnvironmentTests {
    @Test func tagLibLinks() {
        #expect(TagReader.tagLibVersion.hasPrefix("2."))
    }

    @Test func unreadableFileReturnsNil() {
        #expect(TagReader.read(URL(fileURLWithPath: "/nonexistent.flac")) == nil)
    }

    @Test func databaseOpensWithFTS5() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { try $0.execute(sql: "CREATE VIRTUAL TABLE t USING fts5(body)") }
        #expect(try !db.sqliteVersion.isEmpty)
    }
}

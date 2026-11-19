import Foundation
import GRDB
import Testing
@testable import MiniAmpKit

/// Tags written in Shift-JIS or GBK and read as Western text come back readable.
@Suite struct LegacyTextTests {
    /// How the text shows when its bytes are read as Windows-1252, or as Latin-1.
    /// Bytes Windows-1252 leaves undefined (0x81, 0x8D…) come through as Latin-1 control codes,
    /// as taggers pass them.
    func misread(_ text: String, from encoding: String.Encoding, as western: String.Encoding = .windowsCP1252) -> String {
        String(text.data(using: encoding)!.map { byte in
            String(data: Data([byte]), encoding: western).flatMap(\.first) ?? Character(Unicode.Scalar(byte))
        })
    }

    @Test func shiftJISReadAsWestern() {
        let avex = misread("エイベックス", from: .shiftJIS)
        #expect(avex.hasPrefix("ƒGƒC"))
        #expect(LegacyText.repaired(avex) == "エイベックス")
        #expect(LegacyText.repaired(misread("頭文字D", from: .shiftJIS, as: .isoLatin1)) == "頭文字D")
        #expect(LegacyText.repaired(misread("君の名は。 Original", from: .shiftJIS)) == "君の名は。 Original")
    }

    /// The Initial D box set's album artist: avex trax, in Shift-JIS read as Cyrillic.
    @Test func shiftJISReadAsCyrillic() {
        let avex = misread("エイベックス トラックス", from: .shiftJIS, as: .windowsCP1251)
        #expect(avex.hasPrefix("ѓGѓC"))
        #expect(LegacyText.repaired(avex) == "エイベックス トラックス")
    }

    @Test func gbkReadAsWestern() {
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        #expect(LegacyText.repaired(misread("周杰伦", from: gb, as: .isoLatin1)) == "周杰伦")
    }

    @Test func westernTextIsLeftAlone() {
        for name in ["Björk", "Beyoncé", "Sigur Rós", "Mötley Crüe", "Café del Mar", "Ólafur Arnalds", "Aimer", "エイベックス",
                     "幾田りら", "김진산", "Zoë — “Live”", "Déjà Vu",
                     "Кино", "Земфира", "Сплин — «Выхода нет»", "Ђорђе Балашевић", "Мумий Тролль", "Ёлка"] {
            #expect(LegacyText.repaired(name) == name)
        }
    }
}

extension LegacyTextTests {
    @Test func migrationRereadsOnlyMisreadTracks() throws {
        let queue = try GRDB.DatabaseQueue()
        var migrator = AppDatabase.migrator
        try migrator.migrate(queue, upTo: "v9")
        try queue.write { d in
            try BrowseTests.track("Fourth Stage", artist: misread("エイベックス", from: .shiftJIS), album: nil, d)
            try BrowseTests.track("Jóga", artist: "Björk", album: nil, d)
            try d.execute(sql: "UPDATE track SET modifiedAt = 5")
        }
        migrator = AppDatabase.migrator
        try migrator.migrate(queue)
        let reread = try queue.read { try String.fetchAll($0, sql: "SELECT title FROM track WHERE modifiedAt = 0") }
        #expect(reread == ["Fourth Stage"])
    }
}

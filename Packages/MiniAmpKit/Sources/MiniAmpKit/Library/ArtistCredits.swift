import Foundation
import GRDB

/// Splits shared artist credits so "Alan Walker & David Whistle" counts toward Alan Walker
/// and David Whistle, while the song keeps its full credit.
///
/// Tracks and albums still point at the artist row named as the tags have it. `artistMember`
/// maps a split credit to the artists in it, and the `artistCredit` view maps every artist row
/// to the artists it counts toward: its members, or else itself.
///
/// "feat.", "ft.", "featuring", ";" and " / " always split. Commas and "&" are also used in
/// names (Earth, Wind & Fire; Simon & Garfunkel; Tyler, The Creator), so a credit is only
/// split at them when one of its parts is an artist in its own right: credited alone
/// somewhere, or in another credit too.
public enum ArtistCredits {
    /// The names in a credit, in order, and whether it splits regardless of what else is in
    /// the library. A credit with one part doesn't split.
    static func parts(of credit: String) -> (names: [String], certain: Bool) {
        var certain = false
        var pieces = [credit]
        for separator in alwaysSplit {
            let next = pieces.flatMap { split($0, at: separator) }
            if next.count > pieces.count { certain = true }
            pieces = next
        }
        // Then each part at commas and "&", which only count when the credit is known to split.
        pieces = pieces.flatMap { piece in
            maybeSplit.reduce([piece]) { names, separator in names.flatMap { split($0, at: separator) } }
        }
        let names = pieces.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0.lowercased()).inserted }
        return (unique, certain && unique.count > 1)
    }

    private static let alwaysSplit = [" feat. ", " feat ", " ft. ", " ft ", " featuring ", " Feat. ", " Feat ", " Ft. ",
                                      " Featuring ", " FEAT. ", "; ", " / "]
    private static let maybeSplit = [", ", " & "]

    private static func split(_ text: String, at separator: String) -> [String] {
        text.components(separatedBy: separator)
    }

    /// The members of each credit that splits, keyed by the credit, among `names` (every
    /// artist name tracks and albums use).
    static func members(of names: [String]) -> [String: [String]] {
        let split = names.map { ($0, parts(of: $0)) }
        // How often each name shows up: alone, or as a part of a credit.
        var standalone = Set<String>()
        var appearances: [String: Int] = [:]
        for (name, parts) in split {
            if parts.names.count <= 1 { standalone.insert(name.lowercased()) }
            for part in Set(parts.names.map { $0.lowercased() }) where parts.names.count > 1 { appearances[part, default: 0] += 1 }
        }
        var result: [String: [String]] = [:]
        for (name, parts) in split where parts.names.count > 1 {
            let known = parts.names.contains { standalone.contains($0.lowercased()) || appearances[$0.lowercased(), default: 0] > 1 }
            if parts.certain || known { result[name] = parts.names }
        }
        return result
    }

    /// Rewrites `artistMember` from the artist names in use, adding an artist row for each
    /// member the library doesn't have yet. Rows of members already there are kept, so their
    /// ids (remembered by the Artists page) don't change.
    static func rebuild(_ db: Database) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, name FROM artist
            WHERE id IN (SELECT artistId FROM track WHERE artistId IS NOT NULL)
               OR id IN (SELECT artistId FROM album WHERE artistId IS NOT NULL)
            """)
        let ids = Dictionary(rows.map { (($0["name"] as String), $0["id"] as Int64) }, uniquingKeysWith: { a, _ in a })
        let members = members(of: Array(ids.keys))
        try db.execute(sql: "DELETE FROM artistMember")
        for (credit, names) in members {
            guard let creditId = ids[credit] else { continue }
            for (position, name) in names.enumerated() {
                let memberId: Int64
                if let id = try Int64.fetchOne(db, sql: "SELECT id FROM artist WHERE name = ?", arguments: [name]) {
                    memberId = id
                } else {
                    var artist = Artist(name: name)
                    try artist.insert(db)
                    memberId = artist.id!
                }
                try db.execute(sql: "INSERT OR IGNORE INTO artistMember (creditId, memberId, position) VALUES (?, ?, ?)",
                               arguments: [creditId, memberId, position])
            }
        }
    }
}

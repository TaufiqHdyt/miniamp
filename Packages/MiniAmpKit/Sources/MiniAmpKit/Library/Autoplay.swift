import Foundation
import GRDB

/// Picks songs to keep playing when Up Next runs out, from the library and its play history
/// alone: nothing leaves the Mac.
///
/// A candidate scores for sharing an artist, album artist, genre, album, or era with the last
/// few songs queued (the latest counting most), and for having been played around the same
/// time as them before. Songs queued already, played in the last few hours or among the last
/// plays, or cut short the last time they played, are left out or marked down. Picks are drawn
/// at random, weighted by score, at most a couple per artist; when too few songs score, the
/// rest of the batch is drawn from the whole library.
public enum Autoplay {
    public static let batchSize = 10
    /// How many of the latest queued songs the picks are based on.
    static let seedCount = 5
    /// Left out: among the last this many plays...
    static let recentPlays = 50
    /// ...or played this recently.
    static let recentWindow: TimeInterval = 6 * 3600
    /// Plays this close together count as listened to together.
    static let sessionWindow: TimeInterval = 30 * 60
    /// The best-scoring candidates the picks are drawn from.
    static let poolSize = 60
    static let perArtist = 2

    /// Up to `count` tracks to follow `seeds` (the queue's songs in play order; the last ones
    /// count), none of them in `queued`.
    public static func picks<R: RandomNumberGenerator>(
        after seeds: [URL], excluding queued: [URL], count: Int = batchSize, now: Date = Date(),
        using rng: inout R, _ db: Database
    ) throws -> [Track] {
        let candidates = try Candidate.all(db)
        let byPath = Dictionary(candidates.map { ($0.track.path, $0) }) { a, _ in a }
        // Latest first, each library song once.
        var seedIDs = Set<Int64>()
        let seedTracks = seeds.reversed().compactMap { byPath[LibraryPaths.canonical($0)] }
            .filter { seedIDs.insert($0.id).inserted }
            .prefix(seedCount)
        let seedList = Array(seedTracks)

        var excluded = Set(queued.compactMap { byPath[LibraryPaths.canonical($0)]?.id })
        excluded.formUnion(try Int64.fetchAll(db, sql: """
            SELECT trackId FROM play WHERE id IN (SELECT id FROM play ORDER BY playedAt DESC, id DESC LIMIT ?)
            UNION SELECT trackId FROM play WHERE playedAt > ?
            """, arguments: [recentPlays, now.addingTimeInterval(-recentWindow)]))
        excluded.formUnion(seedIDs)

        let together = try playedTogether(with: Array(seedIDs), db)
        let cutShort = try Set(Int64.fetchAll(db, sql: """
            SELECT play.trackId FROM play JOIN track ON track.id = play.trackId
            WHERE play.id IN (SELECT max(id) FROM play GROUP BY trackId)
              AND play.listenedMs < track.durationMs * 0.4
            """))

        var scored: [(candidate: Candidate, score: Double)] = []
        var rest: [Candidate] = []
        for candidate in candidates where !excluded.contains(candidate.id) {
            var score = 0.0
            for (i, seed) in seedList.enumerated() {
                score += candidate.likeness(to: seed) / Double(i + 1)
            }
            score += Double(min(together[candidate.id] ?? 0, 3)) * 1.5
            if cutShort.contains(candidate.id) { score -= 3 }
            if score > 0 { scored.append((candidate, score)) } else { rest.append(candidate) }
        }
        scored.sort { $0.score > $1.score }

        var picked: [Track] = []
        var artistCounts: [Int64: Int] = [:]
        func take(_ candidate: Candidate) {
            if let artist = candidate.track.artistId {
                guard artistCounts[artist, default: 0] < Self.perArtist else { return }
                artistCounts[artist, default: 0] += 1
            }
            picked.append(candidate.track)
        }
        var pool = Array(scored.prefix(poolSize))
        while picked.count < count, !pool.isEmpty {
            let total = pool.reduce(0) { $0 + $1.score }
            var target = Double.random(in: 0..<total, using: &rng)
            let index = pool.firstIndex { target -= $0.score; return target < 0 } ?? pool.count - 1
            take(pool.remove(at: index).candidate)
        }
        rest.shuffle(using: &rng)
        for candidate in rest where picked.count < count { take(candidate) }
        return picked
    }

    /// For each track, how many times it was played within half an hour of one of `seeds`.
    private static func playedTogether(with seeds: [Int64], _ db: Database) throws -> [Int64: Int] {
        guard !seeds.isEmpty else { return [:] }
        let marks = Array(repeating: "?", count: seeds.count).joined(separator: ", ")
        let rows = try Row.fetchAll(db, sql: """
            SELECT q.trackId, count(*) AS n
            FROM play AS p JOIN play AS q
              ON abs(julianday(q.playedAt) - julianday(p.playedAt)) < ?
            WHERE p.trackId IN (\(marks)) AND q.trackId NOT IN (\(marks))
            GROUP BY q.trackId
            """, arguments: StatementArguments([sessionWindow / 86_400] + seeds + seeds))
        return Dictionary(rows.map { ($0["trackId"] as Int64, $0["n"] as Int) }) { a, _ in a }
    }

    /// A playable library track, with what it's compared on.
    struct Candidate {
        var track: Track
        var albumArtistId: Int64?
        var genres: Set<String>
        var id: Int64 { track.id ?? 0 }

        static func all(_ db: Database) throws -> [Candidate] {
            try Row.fetchAll(db, sql: """
                SELECT track.*, album.artistId AS albumArtistId
                FROM track LEFT JOIN album ON album.id = track.albumId
                WHERE track.isEvicted = 0 AND track.durationMs > 0
                """).map { row in
                let track = try Track(row: row)
                return Candidate(track: track, albumArtistId: row["albumArtistId"], genres: Self.genres(track.genre))
            }
        }

        /// "Pop; Dance" → ["pop", "dance"].
        static func genres(_ tag: String?) -> Set<String> {
            Set((tag ?? "").split(whereSeparator: { ";,/".contains($0) })
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty })
        }

        func likeness(to seed: Candidate) -> Double {
            var score = 0.0
            if let artist = track.artistId, artist == seed.track.artistId { score += 4 }
            if let albumArtist = albumArtistId, albumArtist == seed.albumArtistId { score += 2 }
            if !genres.isDisjoint(with: seed.genres) { score += 3 }
            if let album = track.albumId, album == seed.track.albumId { score += 1 }
            if let year = track.year, let other = seed.track.year, abs(year - other) <= 3 { score += 1 }
            return score
        }
    }
}

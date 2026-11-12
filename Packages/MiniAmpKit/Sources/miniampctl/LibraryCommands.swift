import Foundation
import GRDB
import MiniAmpKit

let libraryUsage = """
usage: miniampctl library scan <folder>... [--db PATH] [--no-artwork]
       miniampctl library search <words> [--db PATH]
       miniampctl library watch [--db PATH]     rescan the saved folders, then follow changes (Ctrl-C to quit)
       miniampctl library stats [--db PATH]
       miniampctl library browse [--db PATH]    time the queries the window runs (median of 5)
       miniampctl library history [--db PATH]   the last 50 plays
       miniampctl library recap [YEAR] [--db PATH]   listening stats for a year, or all time
       miniampctl library duplicates [--sound] [--db PATH]  by tags, or by sound (fingerprints what's needed first)
       miniampctl library backup <file> [--db PATH]  back the library up (no settings: those are the app's)
       miniampctl library restore <file> [--db PATH] replace the library with a backup's
The database defaults to $TMPDIR/miniampctl/library.sqlite, with thumbnails in artwork/ beside it.
"""

private struct LibraryOptions {
    var dbPath = FileManager.default.temporaryDirectory.appendingPathComponent("miniampctl/library.sqlite").path
    var artwork = true
    var rest: [String] = []

    init(_ args: some Sequence<String>) {
        var it = args.makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--db": dbPath = it.next() ?? dbPath
            case "--no-artwork": artwork = false
            default: rest.append(arg)
            }
        }
    }

    @MainActor
    func open() throws -> Library {
        let dir = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cache = artwork ? try ArtworkCache(directory: dir.appendingPathComponent("artwork", isDirectory: true)) : nil
        return Library(database: try AppDatabase.at(dbPath), artwork: cache)
    }
}

@MainActor
func libraryCommand(_ args: [String]) async throws {
    guard let command = args.first else { print(libraryUsage); exit(64) }
    let options = LibraryOptions(args.dropFirst())
    switch command {
    case "scan" where !options.rest.isEmpty:
        try await scan(options)
    case "search" where !options.rest.isEmpty:
        let library = try options.open()
        let text = options.rest.joined(separator: " ")
        let start = ContinuousClock.now
        let results = try await library.search(text, limit: 50)
        let elapsed = ContinuousClock.now - start
        for info in results {
            let artist = info.artistName ?? "?"
            let album = info.albumTitle.map { " — \($0)" } ?? ""
            print("\(info.track.title) · \(artist)\(album)  [\(info.track.codec) \(FormatSelection.formatRate(Double(info.track.sampleRate)))]")
        }
        print("\(results.count) result\(results.count == 1 ? "" : "s") in \(elapsed.wholeMilliseconds) ms")
    case "watch":
        let library = try options.open()
        await library.open()
        print("watching \(library.folders.map(\.path).joined(separator: ", ")); \(library.trackCount) tracks")
        var last = (library.trackCount, library.revision)
        var lastScan = library.lastScan
        while true {
            try await Task.sleep(for: .milliseconds(200))
            if let scan = library.lastScan, scan != lastScan {
                lastScan = scan
                print("\(timestamp()) \(describe(scan))")
            }
            if (library.trackCount, library.revision) != last {
                last = (library.trackCount, library.revision)
                print("\(timestamp()) \(library.trackCount) tracks")
            }
            if let error = library.lastError { print("error: \(error)") }
        }
    case "stats":
        let library = try options.open()
        try await printStats(library.database, path: options.dbPath)
    case "browse":
        try await browse(options.open())
    case "history":
        let library = try options.open()
        let plays = try await library.database.writer.read { try Plays.recent(limit: 50, $0) }
        for (play, info) in plays {
            let when = play.playedAt.formatted(date: .abbreviated, time: .shortened)
            let listened = Duration.milliseconds(play.listenedMs).formatted(.time(pattern: .minuteSecond))
            print("\(when)  \(listened)  \(info.track.title) · \(info.artistName ?? "?")")
        }
        print("\(plays.count) play\(plays.count == 1 ? "" : "s")")
    case "backup" where options.rest.count == 1:
        let library = try options.open()
        let url = URL(fileURLWithPath: options.rest[0])
        try LibraryBackup.write(library.database, settings: [:], appVersion: "miniampctl", to: url)
        let info = try LibraryBackup.info(of: url)
        print("backed up \(info.tracks) tracks, \(info.playlists) playlists, \(info.plays) plays to \(url.path)")
    case "restore" where options.rest.count == 1:
        let library = try options.open()
        let url = URL(fileURLWithPath: options.rest[0])
        let info = try LibraryBackup.info(of: url)
        let settings = try LibraryBackup.restore(from: url, into: library.database, artwork: library.artwork)
        print("restored \(info.tracks) tracks, \(info.playlists) playlists, \(info.plays) plays from \(info.createdAt.formatted()) "
              + "(app \(info.appVersion)); \(settings.count) settings in the backup, not applied here")
    case "duplicates":
        let library = try options.open()
        let bySound = options.rest.contains("--sound")
        if bySound {
            let start = ContinuousClock.now
            library.fingerprintTracks()
            await library.waitForFingerprinting()
            print("fingerprinted in \((ContinuousClock.now - start).formatted(.units(allowed: [.seconds, .milliseconds])))")
        }
        let start = ContinuousClock.now
        let groups = try await library.database.writer.read { bySound ? try Duplicates.findBySound($0) : try Duplicates.find($0) }
        for group in groups {
            print("\(group.title) — \(group.artist)")
            for (i, entry) in group.entries.enumerated() {
                print("  \(i == 0 ? "keep" : "    ")  \(entry.info.track.codec) \(entry.info.track.sampleRate) Hz  \(entry.info.track.path)")
            }
        }
        print("\(groups.count) group\(groups.count == 1 ? "" : "s"), found in \((ContinuousClock.now - start).formatted(.units(allowed: [.seconds, .milliseconds])))")
    case "recap":
        let library = try options.open()
        let year = options.rest.first.flatMap(Int.init)
        let stats = try await library.database.writer.read { try ListeningStats.compute(year: year, $0) }
        printRecap(stats)
    default:
        print(libraryUsage)
        exit(64)
    }
}

@MainActor
private func scan(_ options: LibraryOptions) async throws {
    let library = try options.open()
    await library.open()
    await library.waitForScans() // anything already saved

    // How long the main actor goes without running: what a UI would feel as a hang.
    var maxStall: Duration = .zero
    let probe = Task { @MainActor in
        var last = ContinuousClock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
            let now = ContinuousClock.now
            maxStall = max(maxStall, now - last - .milliseconds(5))
            last = now
        }
    }
    let reporter = Task { @MainActor in
        while !Task.isCancelled {
            if let p = library.progress, p.phase == .reading {
                FileHandle.standardError.write(Data("\r  reading \(p.filesRead)/\(p.filesToRead)   ".utf8))
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    let start = ContinuousClock.now
    for path in options.rest {
        try await library.addFolder(URL(fileURLWithPath: path, isDirectory: true))
    }
    await library.waitForScans()
    let elapsed = ContinuousClock.now - start
    probe.cancel()
    reporter.cancel()
    FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))

    if let scan = library.lastScan { print(describe(scan)) }
    if let error = library.lastError { print("error: \(error)") }
    print(String(format: "scan time: %.2f s; longest main-actor stall: %d ms", elapsed.seconds, maxStall.wholeMilliseconds))
    try await printStats(library.database, path: options.dbPath)
}

/// Times what the window asks the library for, as it asks (on the main actor, awaiting a read).
@MainActor
private func browse(_ library: Library) async throws {
    func time<T>(_ label: String, _ body: () async throws -> T, count: (T) -> Int) async rethrows {
        var runs: [Duration] = []
        var n = 0
        for _ in 0..<5 {
            let start = ContinuousClock.now
            n = count(try await body())
            runs.append(ContinuousClock.now - start)
        }
        let median = runs.sorted()[runs.count / 2]
        let padded = label.padding(toLength: 28, withPad: " ", startingAt: 0)
        print(padded + String(format: "%7.1f ms  (%d rows)", median.seconds * 1000, n))
    }
    let artists = try await library.artists()
    let albums = try await library.albums()
    let busiest = artists.max { $0.trackCount < $1.trackCount }
    await library.open()
    try await time("songs, album order", { try await library.tracks(in: .all) }, count: \.count)
    try await time("songs, by title", { try await library.tracks(in: .all, sort: TrackSort(.title)) }, count: \.count)
    try await time("songs, by quality desc", { try await library.tracks(in: .all, sort: TrackSort(.quality, ascending: false)) }, count: \.count)
    try await time("artists", { try await library.artists() }, count: \.count)
    if let busiest {
        try await time("one artist's songs", { try await library.tracks(in: .artist(busiest.id)) }, count: \.count)
        try await time("one artist's albums", { try await library.albums(artistId: busiest.id) }, count: \.count)
    }
    try await time("albums", { try await library.albums() }, count: \.count)
    if let album = albums.first {
        try await time("one album's songs", { try await library.tracks(in: .album(album.id)) }, count: \.count)
    }
    try await time("playlists", { try await library.playlists() }, count: \.count)
    try await time("search \"a\" (1000)", { try await library.search("a", limit: 1000) }, count: \.count)
    try await time("search \"a\" by title", { try await library.search("a", sort: TrackSort(.title), limit: 1000) }, count: \.count)
    let urls = try await library.tracks(in: .all).prefix(200).map(\.track.url)
    try await time("tags for 200 queued files", { try await library.tracks(at: Array(urls)) }, count: \.count)
}

private func printStats(_ database: AppDatabase, path: String) async throws {
    let counts = try await database.writer.read { db in
        (try Track.fetchCount(db), try Album.fetchCount(db), try Artist.fetchCount(db),
         try Int.fetchOne(db, sql: "SELECT count(DISTINCT artworkKey) FROM track") ?? 0,
         try Int.fetchOne(db, sql: "SELECT ifnull(sum(durationMs), 0) FROM track") ?? 0)
    }
    let bytes = ["", "-wal"].compactMap { try? FileManager.default.attributesOfItem(atPath: path + $0)[.size] as? Int }.reduce(0, +)
    print("library: \(counts.0) tracks, \(counts.1) albums, \(counts.2) artists, \(counts.3) cover images, \(counts.4 / 3_600_000) h of audio")
    print(String(format: "database: %.1f MB at %@", Double(bytes) / 1_048_576, path))
}

private func printRecap(_ stats: ListeningStats) {
    let period = stats.year.map(String.init) ?? "all time"
    guard !stats.isEmpty else { print("no plays in \(period)"); return }
    func time(_ d: Duration) -> String { d.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)) }
    print("\(period): \(time(stats.listened)) over \(stats.plays) plays; \(stats.tracks) songs, \(stats.artists) artists, "
          + "\(stats.albums) albums\(stats.newArtists.map { ", \($0) new artists" } ?? ""); longest streak \(stats.longestStreak) days")
    if let day = stats.busiestDay { print("busiest day: \(day.start.formatted(date: .abbreviated, time: .omitted)), \(time(day.listened))") }
    print("top songs:")
    for r in stats.topTracks { print("  \(r.plays)×  \(r.item.track.title) · \(r.item.artistName ?? "?")") }
    print("top artists:")
    for r in stats.topArtists { print("  \(r.plays)×  \(r.item)  (\(time(r.listened)))") }
    print("top albums:")
    for r in stats.topAlbums { print("  \(r.plays)×  \(r.item.title) · \(r.item.artist ?? "?")") }
    print(stats.year == nil ? "by year:" : "by month:")
    for b in stats.timeline {
        let label = b.start.formatted(stats.year == nil ? .dateTime.year() : .dateTime.month(.abbreviated))
        print("  \(label)  \(time(b.listened))")
    }
}

private func describe(_ p: ScanProgress) -> String {
    "\(p.filesFound) files: \(p.added) added, \(p.updated) updated, \(p.moved) moved, \(p.removed) removed, \(p.unreadable) unreadable, \(p.offloaded) offloaded (read \(p.filesRead))"
}

private func timestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: Date())
}

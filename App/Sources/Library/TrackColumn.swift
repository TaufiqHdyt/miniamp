import AppKit
import MiniAmpKit

/// The table's columns. The raw value is the column identifier and the sort key.
enum TrackColumn: String, CaseIterable {
    /// The now-playing bars. Always first and always shown; it has no header and doesn't sort.
    case playing
    case number, title, artist, album, year, genre, time, quality, added

    var title: String {
        switch self {
        case .playing: ""
        case .number: "#"
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .year: "Year"
        case .genre: "Genre"
        case .time: "Time"
        case .quality: "Quality"
        case .added: "Date Added"
        }
    }

    var menuTitle: String {
        switch self {
        case .playing: "Now Playing"
        case .number: "Track Number"
        default: title
        }
    }

    /// Columns the header menu can hide.
    var isOptional: Bool { self != .playing && self != .title }

    /// "#" is album order (or playlist order): sorting by track number alone mixes albums together.
    var sortColumn: TrackSort.Column? {
        switch self {
        case .playing: nil
        case .number: .albumOrder
        case .title: .title
        case .artist: .artist
        case .album: .album
        case .year: .year
        case .genre: .genre
        case .time: .duration
        case .quality: .quality
        case .added: .dateAdded
        }
    }

    /// (min, ideal, max) widths.
    private var widths: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .playing: (20, 20, 20)
        case .number: (24, 32, 50)
        case .title: (120, 280, 2000)
        case .artist, .album: (80, 180, 1000)
        case .year: (36, 44, 70)
        case .genre: (60, 110, 400)
        case .time: (40, 50, 80)
        case .quality: (70, 110, 180)
        case .added: (70, 100, 160)
        }
    }

    /// What the cell shows (an icon, where there is one, is drawn beside it).
    func text(_ info: TrackInfo, position: Int?) -> String {
        switch self {
        case .playing: ""
        case .number: (position ?? info.track.trackNumber).map(String.init) ?? ""
        case .title: info.track.title
        case .artist: info.artistName ?? ""
        case .album: info.albumTitle ?? ""
        case .year: info.track.year.map(String.init) ?? ""
        case .genre: info.track.genre ?? ""
        case .time: TimeFormat.minutes(info.track.durationMs / 1000)
        case .quality: info.track.isEvicted ? "In iCloud" : TrackFormat.short(info.track)
        case .added: info.track.addedAt.formatted(date: .abbreviated, time: .omitted)
        }
    }

    /// Plain text straight from the record, so its length is cheap to compare.
    var isStoredText: Bool { [.title, .artist, .album, .genre].contains(self) }

    @MainActor var font: NSFont {
        switch self {
        case .number, .year, .time: .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        case .quality: .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        default: .systemFont(ofSize: NSFont.systemFontSize)
        }
    }

    @MainActor var textColor: NSColor {
        switch self {
        case .number, .year, .quality: .secondaryLabelColor
        default: .labelColor
        }
    }

    /// How a column resizes: by the user, and (for the text columns) with the table. When
    /// columns are auto-sized, only Title follows the table; the others keep their fitted width.
    @MainActor
    func resizingMask(autoSized: Bool) -> NSTableColumn.ResizingOptions {
        switch self {
        case .playing: []
        case .title: [.autoresizingMask, .userResizingMask]
        case .artist, .album, .genre: autoSized ? .userResizingMask : [.autoresizingMask, .userResizingMask]
        default: .userResizingMask
        }
    }

    var alignment: NSTextAlignment {
        switch self {
        case .number, .time: .right
        default: .left
        }
    }

    @MainActor
    func makeTableColumn() -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(rawValue))
        column.title = title
        column.headerCell.alignment = alignment
        (column.minWidth, column.width, column.maxWidth) = widths
        column.headerToolTip = self == .playing ? "Now playing" : nil
        if sortColumn != nil { column.sortDescriptorPrototype = NSSortDescriptor(key: rawValue, ascending: true) }
        column.isHidden = [.year, .genre, .added].contains(self)
        column.resizingMask = resizingMask(autoSized: false)
        return column
    }

    /// What the header shows for `sort`. Relevance (search) has no column.
    static func sortDescriptors(for sort: TrackSort) -> [NSSortDescriptor] {
        let column: TrackSort.Column = sort.column == .playlistOrder ? .albumOrder : sort.column
        guard let match = allCases.first(where: { $0.sortColumn == column }) else { return [] }
        return [NSSortDescriptor(key: match.rawValue, ascending: sort.ascending)]
    }
}

/// Widths that fit a column's contents.
///
/// Measuring every row of a 10,000-song list on each change would be slow, so only the likely
/// widest strings are measured: for plain text, the 40 longest by byte count (cheap to get);
/// for computed text (times, formats, dates), the longest among an even sample of 300 rows.
@MainActor
enum ColumnFitter {
    static let candidates = 40
    static let sampleSize = 300
    /// Cell insets (2 pt each side) plus a little air, so the widest value doesn't truncate.
    static let padding: CGFloat = 10
    /// Room for the header's sort arrow.
    static let headerExtra: CGFloat = 18

    static func width(_ column: TrackColumn, _ tableColumn: NSTableColumn, tracks: [TrackInfo],
                      positions: [TrackInfo.ID: Int]) -> CGFloat {
        let header = tableColumn.headerCell.cellSize.width + (tableColumn.sortDescriptorPrototype == nil ? 0 : headerExtra)
        var strings: [String]
        if column.isStoredText {
            strings = longest(tracks.lazy.map { column.text($0, position: nil) }, count: candidates)
        } else {
            let step = max(tracks.count / sampleSize, 1)
            let sample = stride(from: 0, to: tracks.count, by: step).lazy.map { tracks[$0] }
            strings = longest(sample.map { column.text($0, position: positions[$0.id]) }, count: candidates)
            if column == .number, !positions.isEmpty { strings.append(String(tracks.count)) }
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: column.font]
        var content = strings.map { ($0 as NSString).size(withAttributes: attributes).width }.max() ?? 0
        // The cloud beside "In iCloud".
        if column == .quality, tracks.contains(where: \.track.isEvicted) { content += 18 }
        let width = (max(header, content + padding)).rounded(.up)
        return min(max(width, tableColumn.minWidth), tableColumn.maxWidth)
    }

    private static func longest(_ strings: some Sequence<String>, count: Int) -> [String] {
        var top: [(Int, String)] = []
        var floor = 0
        for string in strings {
            let length = string.utf8.count
            guard top.count < count || length > floor else { continue }
            top.append((length, string))
            if top.count > count * 2 {
                top.sort { $0.0 > $1.0 }
                top.removeLast(top.count - count)
                floor = top.last?.0 ?? 0
            }
        }
        return top.sorted { $0.0 > $1.0 }.prefix(count).map(\.1)
    }
}

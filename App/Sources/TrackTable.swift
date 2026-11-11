import AppKit
import MiniAmpKit
import SwiftUI

/// A table of tracks, backed by NSTableView.
///
/// SwiftUI's Table visits every row on each update: about 200 ms of main thread for 10,000
/// tracks, every time the list reloads (including after each batch of a scan). NSTableView asks
/// its data source only for the rows on screen, so a reload costs the same at any size.
///
/// Double-click or Return plays the list from that row; Space plays or pauses. Clicking a header
/// sorts by it (the rows arrive sorted from the database). The header's menu shows and hides
/// columns, and the layout is saved.
struct TrackTable: NSViewRepresentable {
    let app: AppState
    let rows: TrackRows
    var inPlaylist = false
    @Binding var sort: TrackSort

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let table = KeyHandlingTableView()
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 6, height: 0)
        for column in TrackColumn.allCases {
            table.addTableColumn(column.makeTableColumn())
        }
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.onReturn = { [weak coordinator] in coordinator?.playSelection() }
        table.onSpace = { [weak coordinator] in coordinator?.togglePlayPause() }

        let rowMenu = NSMenu()
        rowMenu.delegate = coordinator
        table.menu = rowMenu
        let headerMenu = NSMenu()
        headerMenu.delegate = coordinator
        table.headerView?.menu = headerMenu
        coordinator.headerMenu = headerMenu

        // Column widths, order, and visibility persist under this name.
        table.autosaveName = "TrackTable"
        table.autosaveTableColumns = true

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // Reading these here makes SwiftUI call this again when they change.
        // Library paths are canonical, as is what the library queues; a file opened from
        // elsewhere just matches no row.
        let playing = app.currentURL.map { LibraryPaths.normalized($0.path) }
        let isPlaying = app.player.state == .playing
        let waiting: Set<TrackInfo.ID> = app.waitingToPlayID.map { [$0] } ?? []
        context.coordinator.update(self, playing: playing, isPlaying: isPlaying, waiting: waiting)
    }

    // MARK: -

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        weak var table: NSTableView?
        weak var headerMenu: NSMenu?
        private var config: TrackTable?
        private var tracks: [TrackInfo] = []
        /// Playlist positions, by row id.
        private var positions: [TrackInfo.ID: Int] = [:]
        private var rows: TrackRows?
        private var playing: String?
        private var isPlaying = false
        private var waiting: Set<TrackInfo.ID> = []
        private var settingSort = false

        func update(_ config: TrackTable, playing: String?, isPlaying: Bool, waiting: Set<TrackInfo.ID>) {
            self.config = config
            guard let table else { return }

            if config.rows !== rows {
                rows = config.rows
                let selected = Set(table.selectedRowIndexes.map { tracks[$0].id })
                tracks = config.rows.tracks
                positions = config.inPlaylist
                    ? Dictionary(tracks.enumerated().map { ($1.id, $0 + 1) }, uniquingKeysWith: { a, _ in a }) : [:]
                self.playing = playing
                self.isPlaying = isPlaying
                self.waiting = waiting
                refillRows(in: table)
                let rows = IndexSet(tracks.indices.filter { selected.contains(tracks[$0].id) })
                if rows != table.selectedRowIndexes { table.selectRowIndexes(rows, byExtendingSelection: false) }
            } else {
                // Only the rows whose speaker or download state changed.
                var changed = IndexSet()
                if playing != self.playing || isPlaying != self.isPlaying {
                    for path in [self.playing, playing].compactMap({ $0 }) { changed.formUnion(rows(at: path)) }
                }
                if waiting != self.waiting {
                    for id in waiting.symmetricDifference(self.waiting) {
                        if let row = tracks.firstIndex(where: { $0.id == id }) { changed.insert(row) }
                    }
                }
                self.playing = playing
                self.isPlaying = isPlaying
                self.waiting = waiting
                for row in changed { refill(row: row, in: table) }
            }

            let descriptors = TrackColumn.sortDescriptors(for: config.sort)
            if table.sortDescriptors != descriptors {
                settingSort = true
                table.sortDescriptors = descriptors
                settingSort = false
            }
        }

        /// Shows new contents without reloadData, which throws away every row view and builds
        /// new ones (about 100 ms for a screenful). The views that exist are filled in place;
        /// rows scrolled to later get theirs from tableView(_:viewFor:row:).
        private func refillRows(in table: NSTableView) {
            table.noteNumberOfRowsChanged()
            table.enumerateAvailableRowViews { _, row in
                guard row < tracks.count else { return }
                refill(row: row, in: table)
            }
        }

        private func refill(row: Int, in table: NSTableView) {
            guard row < tracks.count else { return }
            let info = tracks[row]
            for (index, tableColumn) in table.tableColumns.enumerated() where !tableColumn.isHidden {
                guard let column = TrackColumn(rawValue: tableColumn.identifier.rawValue),
                      let cell = table.view(atColumn: index, row: row, makeIfNecessary: false) as? TrackCell
                else { continue }
                cell.show(info, column: column, position: positions[info.id], isCurrent: isCurrent(info),
                          isPlaying: isPlaying, isWaiting: waiting.contains(info.id))
            }
        }

        private func isCurrent(_ info: TrackInfo) -> Bool {
            guard let playing else { return false }
            return info.track.path.utf8.elementsEqual(playing.utf8)
        }

        /// The rows showing the file at `path`. Compares bytes: library paths are all NFC, and
        /// String's Unicode-aware hashing and equality made a lookup table of 10,000 paths cost 22 ms.
        private func rows(at path: String) -> IndexSet {
            let bytes = Array(path.utf8)
            return IndexSet(tracks.indices.filter { tracks[$0].track.path.utf8.elementsEqual(bytes) })
        }

        // MARK: Data source and delegate

        func numberOfRows(in tableView: NSTableView) -> Int { tracks.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = TrackColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }
            let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? TrackCell
                ?? TrackCell(column: column)
            let info = tracks[row]
            cell.show(info, column: column, position: positions[info.id],
                      isCurrent: isCurrent(info), isPlaying: isPlaying, isWaiting: waiting.contains(info.id))
            return cell
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !settingSort, let config, let first = tableView.sortDescriptors.first,
                  let column = first.key.flatMap(TrackColumn.init(rawValue:)) else { return }
            var sortColumn = column.sortColumn
            if sortColumn == .albumOrder, config.inPlaylist { sortColumn = .playlistOrder }
            let sort = TrackSort(sortColumn, ascending: first.ascending)
            if sort != config.sort { config.sort = sort }
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            tracks[row].track.title
        }

        // MARK: Actions

        @objc func doubleClicked(_ sender: NSTableView) {
            guard sender.clickedRow >= 0 else { return }
            config?.app.play(tracks, from: tracks[sender.clickedRow].id)
        }

        func playSelection() {
            guard let row = table?.selectedRow, row >= 0 else { return }
            config?.app.play(tracks, from: tracks[row].id)
        }

        func togglePlayPause() {
            guard let app = config?.app else { return }
            app.perform { try await app.player.togglePlayPause() }
        }

        // MARK: Menus

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            if menu === headerMenu { return fillHeaderMenu(menu) }
            guard let table else { return }
            // The clicked row, or the selection if the click was inside it.
            var rows = table.selectedRowIndexes
            if table.clickedRow >= 0, !rows.contains(table.clickedRow) { rows = [table.clickedRow] }
            let chosen = rows.map { tracks[$0] }
            guard !chosen.isEmpty else { return }
            menu.addItem(item("Play") { [self] in config?.app.play(chosen.count > 1 ? chosen : tracks, from: chosen.first?.id) })
            menu.addItem(item("Shuffle") { [self] in config?.app.play(chosen.count > 1 ? chosen : tracks, from: nil, shuffled: true) })
            menu.addItem(.separator())
            if chosen.contains(where: \.track.isEvicted) {
                menu.addItem(item("Download from iCloud") { [self] in config?.app.library?.download(chosen.map(\.track)) })
            }
            menu.addItem(item("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(chosen.map(\.track.url))
            })
        }

        private func fillHeaderMenu(_ menu: NSMenu) {
            guard let table else { return }
            for tableColumn in table.tableColumns {
                guard let column = TrackColumn(rawValue: tableColumn.identifier.rawValue), column != .title else { continue }
                let entry = item(column.menuTitle) { tableColumn.isHidden.toggle() }
                entry.state = tableColumn.isHidden ? .off : .on
                menu.addItem(entry)
            }
        }

        private func item(_ title: String, _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
            let item = ClosureMenuItem(title: title, action: action)
            return item
        }
    }
}

/// The table's columns. The raw value is the column identifier and the sort key.
enum TrackColumn: String, CaseIterable {
    case number, title, artist, album, year, genre, time, quality, added

    var title: String {
        switch self {
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

    var menuTitle: String { self == .number ? "Track Number" : title }

    /// "#" is album order (or playlist order): sorting by track number alone mixes albums together.
    var sortColumn: TrackSort.Column {
        switch self {
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
        column.sortDescriptorPrototype = NSSortDescriptor(key: rawValue, ascending: true)
        column.isHidden = [.year, .genre, .added].contains(self)
        column.resizingMask = self == .title || self == .artist || self == .album || self == .genre
            ? [.autoresizingMask, .userResizingMask] : .userResizingMask
        return column
    }

    /// What the header shows for `sort`. Relevance (search) has no column.
    static func sortDescriptors(for sort: TrackSort) -> [NSSortDescriptor] {
        let column: TrackSort.Column = sort.column == .playlistOrder ? .albumOrder : sort.column
        guard let match = allCases.first(where: { $0.sortColumn == column }) else { return [] }
        return [NSSortDescriptor(key: match.rawValue, ascending: sort.ascending)]
    }
}

/// One cell: a text field, plus a speaker (title), a cloud, or a spinner (quality) when needed.
///
/// Laid out by frame, not Auto Layout: a screenful of constraint-based cells took ~40 ms to
/// create and as long again to solve.
private final class TrackCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var spinner: NSProgressIndicator?
    private var showsIcon = false

    init(column: TrackColumn) {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier(column.rawValue)
        label.lineBreakMode = .byTruncatingTail
        label.alignment = column.alignment
        label.cell?.truncatesLastVisibleLine = true
        icon.isHidden = true
        icon.imageScaling = .scaleProportionallyDown
        textField = label
        imageView = icon
        addSubview(icon)
        addSubview(label)
        switch column {
        case .number, .year:
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            label.textColor = .secondaryLabelColor
        case .time:
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        case .quality:
            label.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            label.textColor = .secondaryLabelColor
        default:
            label.font = .systemFont(ofSize: NSFont.systemFontSize)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let height = label.intrinsicContentSize.height
        let y = ((bounds.height - height) / 2).rounded()
        var x: CGFloat = 2
        if showsIcon || spinner != nil {
            let side: CGFloat = 14
            let iconFrame = NSRect(x: x, y: ((bounds.height - side) / 2).rounded(), width: side, height: side)
            icon.frame = iconFrame
            spinner?.frame = iconFrame
            x += side + 4
        }
        label.frame = NSRect(x: x, y: y, width: max(bounds.width - x - 2, 0), height: height)
    }

    func show(_ info: TrackInfo, column: TrackColumn, position: Int?, isCurrent: Bool, isPlaying: Bool, isWaiting: Bool) {
        var symbol: String?
        var help: String?
        var text: String
        switch column {
        case .number: text = (position ?? info.track.trackNumber).map(String.init) ?? ""
        case .title:
            text = info.track.title
            if isCurrent { symbol = isPlaying ? "speaker.wave.2.fill" : "speaker.fill" }
        case .artist: text = info.artistName ?? ""
        case .album: text = info.albumTitle ?? ""
        case .year: text = info.track.year.map(String.init) ?? ""
        case .genre: text = info.track.genre ?? ""
        case .time: text = TimeFormat.minutes(info.track.durationMs / 1000)
        case .quality:
            if isWaiting {
                text = "Downloading…"
                help = "Downloading from iCloud; plays when it's ready"
            } else if info.track.isEvicted {
                text = "In iCloud"
                symbol = "icloud"
                help = "Not downloaded. Double-click to download and play."
            } else {
                text = TrackFormat.short(info.track)
            }
        case .added: text = info.track.addedAt.formatted(date: .abbreviated, time: .omitted)
        }
        if label.stringValue != text { label.stringValue = text }
        toolTip = help
        if let symbol {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            icon.contentTintColor = column == .title ? .controlAccentColor : .secondaryLabelColor
        }
        let layoutChanged = showsIcon != (symbol != nil) || (spinner != nil) != (column == .quality && isWaiting)
        showsIcon = symbol != nil
        icon.isHidden = !showsIcon
        showSpinner(column == .quality && isWaiting)
        if layoutChanged { needsLayout = true }
    }

    private func showSpinner(_ show: Bool) {
        if show, spinner == nil {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .mini
            addSubview(spinner)
            spinner.startAnimation(nil)
            self.spinner = spinner
        } else if !show, let spinner {
            spinner.removeFromSuperview()
            self.spinner = nil
        }
    }
}

/// Return plays the selection and Space plays or pauses, as in the rest of the window.
private final class KeyHandlingTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onSpace: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        switch event.charactersIgnoringModifiers {
        case "\r" where plain, "\u{3}" where plain: onReturn?()
        case " " where plain: onSpace?()
        default: super.keyDown(with: event)
        }
    }
}

/// A menu item that runs a closure.
@MainActor
private final class ClosureMenuItem: NSMenuItem {
    private let run: @MainActor () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}

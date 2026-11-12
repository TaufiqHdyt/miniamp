import AppKit
import MiniAmpKit
import SwiftUI

/// A table of tracks, backed by NSTableView.
///
/// SwiftUI's Table visits every row on each update: about 200 ms of main thread for 10,000
/// tracks, every time the list reloads (including after each batch of a scan). NSTableView asks
/// its data source only for the rows on screen, so a reload costs the same at any size.
///
/// Double-click or Return plays the list from that row; Space plays or pauses; ⌘I opens Get
/// Info. Clicking a header sorts by it (the rows arrive sorted from the database). The header's
/// menu shows and hides columns, and the layout is saved.
///
/// In a playlist, rows can be dragged into a new order (while it's sorted by its own order),
/// and Delete removes them from the playlist.
struct TrackTable: NSViewRepresentable {
    let app: AppState
    let rows: TrackRows
    /// The playlist the rows are, if they are one.
    var playlist: Int64?
    @Binding var sort: TrackSort

    var inPlaylist: Bool { playlist != nil }

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
        table.onDelete = { [weak coordinator] in coordinator?.removeSelectionFromPlaylist() }
        table.onGetInfo = { [weak coordinator] in coordinator?.getInfoForSelection() }
        table.registerForDraggedTypes([Coordinator.rowType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)

        let rowMenu = NSMenu()
        rowMenu.delegate = coordinator
        table.menu = rowMenu
        let headerMenu = NSMenu()
        headerMenu.delegate = coordinator
        table.headerView?.menu = headerMenu
        coordinator.headerMenu = headerMenu

        // Column widths, order, and visibility persist under this name. (v2 added the
        // now-playing column; a layout saved before it would put it anywhere.)
        table.autosaveName = "TrackTable.v2"
        table.autosaveTableColumns = true

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        coordinator.table = table
        coordinator.applyResizingMasks(in: table)
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
        /// Columns fit their contents after every change to the list (header menu › Auto-Size Columns).
        private var autoSizesColumns = UserDefaults.standard.bool(forKey: Coordinator.autoSizeKey) {
            didSet { UserDefaults.standard.set(autoSizesColumns, forKey: Coordinator.autoSizeKey) }
        }
        private var fitting = false
        /// The songs (in any order) and columns the widths were last fitted to: a re-sort can't
        /// change them, so it skips the measuring.
        private var fittedFor: (count: Int, idSum: Int64, columns: [String])?
        static let autoSizeKey = "autoSizeColumns"
        /// Playlist rows being dragged within the table: their playlist item ids.
        static let rowType = NSPasteboard.PasteboardType("dev.miniamp.playlist-items")

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
                if autoSizesColumns { fitAllColumns(in: table, unlessUnchanged: true) }
                let rows = IndexSet(tracks.indices.filter { selected.contains(tracks[$0].id) })
                if rows != table.selectedRowIndexes { table.selectRowIndexes(rows, byExtendingSelection: false) }
            } else {
                // Only the rows whose playing bars or download state changed.
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
            guard var sortColumn = column.sortColumn else { return }
            if sortColumn == .albumOrder, config.inPlaylist { sortColumn = .playlistOrder }
            let sort = TrackSort(sortColumn, ascending: first.ascending)
            if sort != config.sort { config.sort = sort }
        }

        /// The now-playing column stays first.
        func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
            let playing = NSUserInterfaceItemIdentifier(TrackColumn.playing.rawValue)
            return tableView.tableColumns[columnIndex].identifier != playing && newColumnIndex != 0
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            tracks[row].track.title
        }

        // MARK: Actions

        // MARK: Playlist order

        /// Rows can be dragged only where the drop means something: in a playlist shown in its own order.
        private var canReorder: Bool {
            guard let config, config.inPlaylist else { return false }
            return config.sort == TrackSort(.playlistOrder)
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard canReorder, let item = tracks[row].playlistItemId else { return nil }
            let entry = NSPasteboardItem()
            entry.setString(String(item), forType: Self.rowType)
            return entry
        }

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard canReorder, info.draggingSource as? NSTableView === tableView else { return [] }
            if operation == .on { tableView.setDropRow(row, dropOperation: .above) }
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            guard canReorder, let playlist = config?.playlist, let library = config?.app.library else { return false }
            let items = (info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: Self.rowType).flatMap(Int64.init) }
            guard !items.isEmpty else { return false }
            // Shown at once; the reload after the write brings the same order.
            let moving = Set(items)
            let moved = tracks.filter { $0.playlistItemId.map(moving.contains) ?? false }
            var rest = tracks.filter { !($0.playlistItemId.map(moving.contains) ?? false) }
            let at = row - tracks[..<min(row, tracks.count)].filter { $0.playlistItemId.map(moving.contains) ?? false }.count
            rest.insert(contentsOf: moved, at: at)
            showLocally(rest, in: tableView)
            tableView.selectRowIndexes(IndexSet(at..<(at + moved.count)), byExtendingSelection: false)
            config?.app.perform { try await library.movePlaylistItems(items, in: playlist, to: row) }
            return true
        }

        func removeSelectionFromPlaylist() {
            guard let table, let config, let playlist = config.playlist, let library = config.app.library else { return }
            let rows = table.selectedRowIndexes
            remove(rows.map { tracks[$0] }, from: playlist, library: library, in: table)
        }

        private func remove(_ chosen: [TrackInfo], from playlist: Int64, library: Library, in table: NSTableView) {
            let items = chosen.compactMap(\.playlistItemId)
            guard !items.isEmpty else { return }
            let gone = Set(items)
            let first = tracks.firstIndex { $0.playlistItemId.map(gone.contains) ?? false } ?? 0
            showLocally(tracks.filter { !($0.playlistItemId.map(gone.contains) ?? false) }, in: table)
            if !tracks.isEmpty { table.selectRowIndexes([min(first, tracks.count - 1)], byExtendingSelection: false) }
            config?.app.perform { try await library.removeFromPlaylist(playlist, itemIds: items) }
        }

        /// Shows an edit before the database has it. Positions follow the new order.
        private func showLocally(_ new: [TrackInfo], in table: NSTableView) {
            tracks = new
            positions = Dictionary(tracks.enumerated().map { ($1.id, $0 + 1) }, uniquingKeysWith: { a, _ in a })
            table.deselectAll(nil)
            table.reloadData()
        }

        func getInfoForSelection() {
            guard let table else { return }
            let chosen = table.selectedRowIndexes.map { tracks[$0] }
            config?.app.editTags(of: chosen)
        }

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
            if let app = config?.app, app.library != nil {
                let local = chosen.filter { !$0.track.isEvicted }
                let info = item("Get Info…") { app.editTags(of: local) }
                info.keyEquivalent = "i"
                info.isEnabled = !local.isEmpty
                if local.isEmpty { info.action = nil }
                menu.addItem(info)
                menu.addItem(addToPlaylistItem(chosen, app: app))
                let analyze = item("Analyze Loudness") { app.analyzeLoudness(of: local) }
                if local.isEmpty || app.library?.loudnessProgress != nil { analyze.action = nil }
                menu.addItem(analyze)
                if let playlist = config?.playlist, let library = app.library {
                    menu.addItem(item("Remove from Playlist") { [self] in
                        guard let table = self.table else { return }
                        remove(chosen, from: playlist, library: library, in: table)
                    })
                }
                menu.addItem(.separator())
            }
            if chosen.contains(where: \.track.isEvicted) {
                menu.addItem(item("Download from iCloud") { [self] in config?.app.library?.download(chosen.map(\.track)) })
            }
            menu.addItem(item("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(chosen.map(\.track.url))
            })
        }

        private func addToPlaylistItem(_ chosen: [TrackInfo], app: AppState) -> NSMenuItem {
            let submenu = NSMenu()
            submenu.addItem(item("New Playlist from Selection") { app.newPlaylist(with: chosen) })
            let others = app.playlists.filter { $0.id != config?.playlist }
            if !others.isEmpty { submenu.addItem(.separator()) }
            for playlist in others {
                submenu.addItem(item(playlist.name) { app.add(chosen, toPlaylist: playlist.id) })
            }
            let entry = NSMenuItem(title: "Add to Playlist", action: nil, keyEquivalent: "")
            entry.submenu = submenu
            return entry
        }

        private func fillHeaderMenu(_ menu: NSMenu) {
            guard let table else { return }
            // The column under the right-click, if any.
            var clicked: NSTableColumn?
            if let header = table.headerView, let event = NSApp.currentEvent {
                let index = header.column(at: header.convert(event.locationInWindow, from: nil))
                if index >= 0, table.tableColumns[index].identifier.rawValue != TrackColumn.playing.rawValue {
                    clicked = table.tableColumns[index]
                }
            }
            if let clicked {
                menu.addItem(item("Size Column to Fit") { [self] in
                    fit(clicked, in: table)
                })
            }
            menu.addItem(item("Size All Columns to Fit") { [self] in fitAllColumns(in: table) })
            let auto = item("Auto-Size Columns") { [self] in
                autoSizesColumns.toggle()
                applyResizingMasks(in: table)
                if autoSizesColumns { fitAllColumns(in: table) }
            }
            auto.state = autoSizesColumns ? .on : .off
            menu.addItem(auto)
            menu.addItem(.separator())
            for tableColumn in table.tableColumns {
                guard let column = TrackColumn(rawValue: tableColumn.identifier.rawValue), column.isOptional else { continue }
                let entry = item(column.menuTitle) { [self] in
                    tableColumn.isHidden.toggle()
                    if autoSizesColumns { fitAllColumns(in: table) }
                }
                entry.state = tableColumn.isHidden ? .off : .on
                menu.addItem(entry)
            }
        }

        // MARK: Column sizing

        /// Double-clicking a column's divider.
        func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
            let tableColumn = tableView.tableColumns[column]
            guard let kind = TrackColumn(rawValue: tableColumn.identifier.rawValue) else { return tableColumn.width }
            return ColumnFitter.width(kind, tableColumn, tracks: tracks, positions: positions)
        }

        /// Dragging a column's edge by hand turns auto-sizing off, so the width sticks.
        func tableViewColumnDidResize(_ notification: Notification) {
            guard autoSizesColumns, !fitting, NSApp.currentEvent?.type == .leftMouseDragged, let table else { return }
            autoSizesColumns = false
            applyResizingMasks(in: table)
        }

        func applyResizingMasks(in table: NSTableView) {
            for tableColumn in table.tableColumns {
                guard let kind = TrackColumn(rawValue: tableColumn.identifier.rawValue) else { continue }
                tableColumn.resizingMask = kind.resizingMask(autoSized: autoSizesColumns)
            }
        }

        private func fit(_ tableColumn: NSTableColumn, in table: NSTableView) {
            guard let kind = TrackColumn(rawValue: tableColumn.identifier.rawValue) else { return }
            fitting = true
            tableColumn.width = ColumnFitter.width(kind, tableColumn, tracks: tracks, positions: positions)
            fitting = false
        }

        /// Every shown column fits its contents, and Title takes whatever width is left.
        private func fitAllColumns(in table: NSTableView, unlessUnchanged: Bool = false) {
            let shown = table.tableColumns.filter { !$0.isHidden }.map(\.identifier.rawValue)
            let key = (count: tracks.count, idSum: tracks.reduce(Int64(0)) { $0 &+ $1.id }, columns: shown)
            if unlessUnchanged, let fittedFor, fittedFor.count == key.count, fittedFor.idSum == key.idSum,
               fittedFor.columns == key.columns { return }
            fittedFor = key
            fitting = true
            defer { fitting = false }
            var title: NSTableColumn?
            var used: CGFloat = 0
            for tableColumn in table.tableColumns where !tableColumn.isHidden {
                guard let kind = TrackColumn(rawValue: tableColumn.identifier.rawValue) else { continue }
                if kind == .title { title = tableColumn; continue }
                if kind != .playing {
                    let width = ColumnFitter.width(kind, tableColumn, tracks: tracks, positions: positions)
                    if abs(width - tableColumn.width) > 0.5 { tableColumn.width = width }
                }
                used += tableColumn.width + table.intercellSpacing.width
            }
            guard let title else { return }
            let available = (table.enclosingScrollView?.contentSize.width ?? table.bounds.width) - table.intercellSpacing.width
            let fitted = ColumnFitter.width(.title, title, tracks: tracks, positions: positions)
            let width = min(max(available - used, fitted, title.minWidth), title.maxWidth)
            if abs(width - title.width) > 0.5 { title.width = width }
        }

        private func item(_ title: String, _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
            let item = ClosureMenuItem(title: title, action: action)
            return item
        }
    }
}

/// One cell: a text field, plus the playing bars, a cloud, or a spinner (quality) when needed.
///
/// Laid out by frame, not Auto Layout: a screenful of constraint-based cells took ~40 ms to
/// create and as long again to solve.
private final class TrackCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var spinner: NSProgressIndicator?
    /// The playing column's bars, made the first time this cell shows the song playing.
    private var bars: PlayingBarsView?
    private var showsIcon = false

    private let column: TrackColumn

    init(column: TrackColumn) {
        self.column = column
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
        label.font = column.font
        label.textColor = column.textColor
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        if column == .playing {
            let side: CGFloat = 14
            icon.frame = NSRect(x: ((bounds.width - side) / 2).rounded(), y: ((bounds.height - side) / 2).rounded(),
                                width: side, height: side)
            bars?.frame = NSRect(x: ((bounds.width - side) / 2).rounded(), y: ((bounds.height - 12) / 2).rounded(),
                                 width: side, height: 12)
            label.frame = .zero
            return
        }
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
        var text = column.text(info, position: position)
        switch column {
        case .playing:
            if isCurrent {
                help = isPlaying ? "Now playing" : "Paused"
                if bars == nil {
                    let bars = PlayingBarsView()
                    addSubview(bars)
                    self.bars = bars
                    needsLayout = true
                }
            }
            bars?.isHidden = !isCurrent
            bars?.isPlaying = isCurrent && isPlaying
        case .quality:
            if isWaiting {
                text = "Downloading…"
                help = "Downloading from iCloud; plays when it's ready"
            } else if info.track.isEvicted {
                symbol = "icloud"
                help = "Not downloaded. Double-click to download and play."
            }
        default:
            break
        }
        if label.stringValue != text { label.stringValue = text }
        toolTip = help
        if let symbol {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            icon.contentTintColor = column == .playing ? .controlAccentColor : .secondaryLabelColor
            icon.setAccessibilityLabel(help)
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

/// Return plays the selection and Space plays or pauses, as in the rest of the window. Delete
/// (in a playlist) removes the selection from it; ⌘I opens Get Info.
private final class KeyHandlingTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onSpace: (() -> Void)?
    var onDelete: (() -> Void)?
    var onGetInfo: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        let plain = modifiers.isEmpty
        switch event.charactersIgnoringModifiers {
        case "\r" where plain, "\u{3}" where plain: onReturn?()
        case " " where plain: onSpace?()
        case "\u{7F}" where plain, "\u{F728}" where plain: onDelete?()
        case "i" where modifiers == .command: onGetInfo?()
        default: super.keyDown(with: event)
        }
    }

    /// ⌘I reaches the table as a key equivalent before it's a key press.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           event.charactersIgnoringModifiers == "i", window?.firstResponder === self {
            onGetInfo?()
            return true
        }
        return super.performKeyEquivalent(with: event)
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

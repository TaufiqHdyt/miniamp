import AppKit
import MiniAmpKit
import os
import SwiftUI
import UniformTypeIdentifiers

struct MainWindow: View {
    @Bindable var app: AppState
    @AppStorage("showsLibrarySidebar") private var showsSidebar = true
    @SceneStorage("sidebarSelection") private var selection: SidebarItem = .songs
    @FocusState private var searchFocused: Bool
    @State private var handledSearchRequest = 0
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            windowContent
            Divider()
            PlayerBar(app: app)
        }
        .transaction(value: app.fullView) {
            $0.animation = nil
            $0.disablesAnimations = true
        }
        .toolbar(removing: .title)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .frame(minWidth: 860, minHeight: 520)
        .background(WindowKeyboard(app: app).allowsHitTesting(false))
        .onChange(of: app.equalizerRequests) { app.showEqualizer(openWindow) }
        .sheet(item: $app.keyboardSheet, onDismiss: {
            guard let action = app.commandAfterSheet else { return }
            app.commandAfterSheet = nil
            app.run(action)
        }) { sheet in
            switch sheet {
            case .jump: JumpView(app: app)
            case .time: JumpTimeView(app: app)
            case .commands: CommandPalette(app: app)
            case .shortcuts: ShortcutHelp(app: app)
            case .output: OutputPanel(player: app.player)
            }
        }
        .fileImporter(isPresented: $app.importingFiles, allowedContentTypes: AppState.playableTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): app.perform { try await app.player.setQueue(urls) }
            case .failure(let e): app.error = e.localizedDescription
            }
        }
        .fileImporter(isPresented: $app.addingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): app.perform { try await app.library?.addFolder(url) }
            case .failure(let e): app.error = e.localizedDescription
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { app.error != nil }, set: { if !$0 { app.error = nil } })) {
            Button("OK") { app.error = nil }
        } message: {
            Text(app.error ?? "")
        }
        .onChange(of: app.library?.revision) { app.libraryChanged() }
        .task(id: app.library?.revision) {
            await app.reloadPlaylists()
            if case .playlist(let id) = selection, !app.playlists.contains(where: { $0.id == id }) {
                selectLibraryPage(.songs)
            }
        }
        .onChange(of: app.player.queue.current == nil) { if app.player.queue.current == nil, app.fullView != .upNext { app.fullView = nil } }
        .onChange(of: app.sidebarRequest) {
            guard let item = app.sidebarRequest else { return }
            selectLibraryPage(item)
            app.contentFocusRequests += 1
            app.sidebarRequest = nil
        }
        .sheet(item: $app.editingTags) { target in
            TagEditor(app: app, tracks: target.tracks)
        }
        .sheet(item: $app.editingLyrics) { target in
            LyricsEditor(app: app, target: target)
        }
        // Nobody sees the position while the window is hidden or covered; stop redrawing it.
        .onWindowVisibilityChange { app.mainWindowVisible = $0 }
        .task { await start() }
    }

    @ViewBuilder
    private var windowContent: some View {
        if app.fullView == .upNext {
            NowPlayingView(app: app)
                .navigationTitle("Queue")
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        HStack(spacing: Theme.Spacing.m) {
                            Button { app.showFullView(nil) } label: {
                                Label("Back to Library", systemImage: "chevron.left")
                                    .labelStyle(.iconOnly)
                            }
                            .keyboardShortcut(.cancelAction)
                            .focusable(false)
                            navigationTitleLabel("Queue")
                        }
                    }
                    .withoutSharedBackground()
                }
        } else if let mode = app.fullView, let url = app.currentURL {
            FullPlayingView(app: app, url: url, mode: mode)
        } else {
            HSplitView {
                if showsSidebar {
                    Sidebar(app: app, selection: Binding(get: { selection }, set: selectLibraryPage))
                        .frame(minWidth: 180, idealWidth: 210, maxWidth: 280, maxHeight: .infinity)
                }
                detail
                    .frame(minWidth: 550, maxWidth: .infinity, maxHeight: .infinity)
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    HStack(spacing: Theme.Spacing.m) {
                        Button { showsSidebar.toggle() } label: {
                            Label(showsSidebar ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left")
                                .labelStyle(.iconOnly)
                        }
                        .focusable(false)
                        .help(showsSidebar ? "Hide Sidebar" : "Show Sidebar")
                        navigationTitleLabel(libraryTitle)
                    }
                }
                .withoutSharedBackground()
                if #available(macOS 26, *) {
                    ToolbarSpacer(.flexible, placement: .automatic)
                    ToolbarItem(placement: .automatic) {
                        librarySearch
                    }
                    .withoutSharedBackground()
                } else {
                    ToolbarItem(placement: .primaryAction) {
                        librarySearch.padding(.leading, Theme.Spacing.l)
                    }
                }
            }
        }
    }

    private var libraryTitle: String {
        if let destination = app.libraryPath.last {
            switch destination {
            case .album(_, let title): return title ?? "Album"
            case .artist(_, let name), .artistSongs(_, let name): return name
            }
        }
        if app.isSearching { return "Search" }
        if case .playlist(let id) = selection {
            return app.playlists.first { $0.id == id }?.name ?? selection.title
        }
        return selection.title
    }

    private func navigationTitleLabel(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 260, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private var librarySearch: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search library", text: Binding(get: { app.searchText }, set: updateLibrarySearch))
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .accessibilityLabel("Search library")
                .focused($searchFocused)
                .onSubmit {
                    guard app.isSearching else { return }
                    searchFocused = false
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    app.contentFocusRequests += 1
                }
                .onChange(of: app.searchFocusRequests, initial: true) { _, request in
                    guard request > handledSearchRequest else { return }
                    handledSearchRequest = request
                    searchFocused = true
                }
            if !app.searchText.isEmpty {
                Button {
                    updateLibrarySearch("")
                    searchFocused = true
                } label: {
                    Label("Clear Search", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .foregroundStyle(.secondary)
                .help("Clear Search")
            } else if !searchFocused {
                Text("⌘F")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Theme.Spacing.s)
        .frame(width: 224, height: 28)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.medium)
                .strokeBorder(searchFocused ? Color.accentColor : Color.primary.opacity(0.14))
                .allowsHitTesting(false)
        }
        .onExitCommand {
            updateLibrarySearch("")
            searchFocused = false
            NSApp.keyWindow?.makeFirstResponder(nil)
            app.contentFocusRequests += 1
        }
    }

    private func selectLibraryPage(_ item: SidebarItem) {
        updateLibrarySearch("")
        app.fullView = nil
        selection = item
    }

    private func updateLibrarySearch(_ text: String) {
        app.libraryPath = []
        app.searchText = text
    }

    @ViewBuilder
    private var detail: some View {
        if let library = app.library {
            // Album and artist pages open over the page showing, with Back to return.
            NavigationStack(path: $app.libraryPath) {
                page(library)
                    .navigationDestination(for: LibraryDestination.self) { destination in
                        LibraryDestinationView(app: app, library: library, destination: destination)
                    }
            }
            .transaction(value: selection) {
                $0.animation = nil
                $0.disablesAnimations = true
            }
            .transaction(value: app.libraryPath) {
                $0.animation = nil
                $0.disablesAnimations = true
            }
        } else {
            ContentUnavailableView("The library couldn't be opened", systemImage: "externaldrive.badge.exclamationmark",
                                   description: Text("Open files with File › Open… to play them."))
        }
    }

    @ViewBuilder
    private func page(_ library: Library) -> some View {
        if app.isSearching {
            SearchResultsView(app: app, library: library,
                              query: app.searchText.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            switch selection {
            case .home:
                HomeView(app: app, library: library)
            case .songs:
                TrackListView(app: app, library: library, scope: .all, title: "Songs")
            case .artists:
                ArtistsView(app: app, library: library)
            case .albums:
                AlbumsView(app: app, library: library)
            case .stats:
                StatsView(app: app, library: library)
            case .duplicates:
                DuplicatesView(app: app, library: library)
            case .playlist(let id):
                TrackListView(app: app, library: library, scope: .playlist(id),
                              title: app.playlists.first { $0.id == id }?.name ?? selection.title)
                    .id(id)
            }
        }
    }

    private func start() async {
        Logger(subsystem: "dev.miniamp", category: "app").debug("window opened")
        let defaults = UserDefaults.standard
        // Hooks for automated checks: in Debug builds, or in any build when a test database
        // is in use (-libraryDatabase), so a Release check never touches the real library.
        //   miniamp -sidebar albums            (home, songs, artists, albums, stats, duplicates, or playlist:<id>)
        //   miniamp -libraryFolder /path/in/container
        var addsFolders = defaults.string(forKey: "libraryDatabase") != nil
        #if DEBUG
        addsFolders = true
        #endif
        if addsFolders, let item = defaults.string(forKey: "sidebar").flatMap(SidebarItem.init(rawValue:)) {
            selection = item
        }
        if addsFolders, defaults.bool(forKey: "showQueue") {
            app.showFullView(.upNext)
        } else {
            app.contentFocusRequests += 1
        }
        await app.library?.open()
        if addsFolders, let path = defaults.string(forKey: "libraryFolder") {
            app.perform { try await app.library?.addFolder(URL(fileURLWithPath: path, isDirectory: true)) }
        }
        //   miniamp -autoplay /path/in/container/file.flac [-hog YES]
        //   miniamp -autoplay '(/path/a.flac, /path/b.flac)' [-sleepAtEndOfTrack YES]
        if addsFolders, let paths = defaults.stringArray(forKey: "autoplay") ?? defaults.string(forKey: "autoplay").map({ [$0] }) {
            if defaults.object(forKey: "hog") != nil { app.player.hogMode = defaults.bool(forKey: "hog") }
            app.perform {
                try await app.player.setQueue(paths.map { URL(fileURLWithPath: $0) })
                //   ... -fullView visualizer   (or lyrics / upNext)
                switch defaults.string(forKey: "fullView") {
                case "visualizer": app.fullView = .visualizer
                case "lyrics": app.fullView = .lyrics
                case "upNext": app.fullView = .upNext
                default: break
                }
                if defaults.bool(forKey: "sleepAtEndOfTrack") { app.sleepTimer.stopAtEndOfTrack() }
            }
        } else {
            await app.openPlaybackSession()
        }
    }
}

import MiniAmpKit
import os
import SwiftUI
import UniformTypeIdentifiers

struct MainWindow: View {
    @Bindable var app: AppState
    @SceneStorage("sidebarSelection") private var selection: SidebarItem = .home
    @FocusState private var searchFocused: Bool
    var body: some View {
        Group {
            if #available(macOS 26, *) {
                // The library runs to the bottom of the window and the bar floats over it, as
                // glass: lists scroll under it, fading out before the window's edge, and leave
                // room after their last row to clear it. Laid over the whole window, not the
                // split view, which slides about as the sidebar opens and closes.
                ZStack(alignment: .bottom) {
                    split
                        .contentMargins(.bottom, app.playerBarInset, for: .scrollContent)
                    // Not over full lyrics or the visualizer: their wash runs to the window's edge.
                    if app.fullView == nil { BarFade(height: app.playerBarInset) }
                    PlayerBar(app: app)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { app.playerBarInset = $0 }
                }
            } else {
                VStack(spacing: 0) {
                    split
                    Divider()
                    PlayerBar(app: app)
                }
            }
        }
        .frame(minWidth: 860, minHeight: 520)
        .onKeyPress(.space) {
            app.perform { try await app.player.togglePlayPause() }
            return .handled
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
        // Anything chosen in the sidebar, or searched for, goes back from the full-size lyrics.
        .onChange(of: selection) {
            app.fullView = nil
            app.libraryPath = []
        }
        .onChange(of: app.searchText) {
            if app.isSearching { app.fullView = nil }
            app.libraryPath = []
        }
        .onChange(of: app.player.queue.current == nil) { if app.player.queue.current == nil { app.fullView = nil } }
        .onChange(of: app.sidebarRequest) {
            guard let item = app.sidebarRequest else { return }
            app.searchText = ""
            selection = item
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

    /// Fades what scrolls under the floating bar into the window's background toward the
    /// bottom edge, so rows don't show in the gap below the bar.
    private struct BarFade: View {
        let height: CGFloat

        var body: some View {
            Rectangle()
                .fill(.background)
                .mask {
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.85), location: 0.55),
                                           .init(color: .black, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .frame(height: height + Theme.Spacing.l)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var split: some View {
        NavigationSplitView {
            Sidebar(app: app, selection: $selection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
        } detail: {
            detail
                // Not while nothing is playing, rather than a column saying so.
                .inspector(isPresented: Binding(get: { app.showsNowPlaying && app.currentURL != nil },
                                                set: { app.showsNowPlaying = $0 })) {
                    NowPlayingView(app: app)
                        .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
                }
        }
        // As in Apple Music: search at the top of the sidebar (in the toolbar while the
        // sidebar is hidden). Each page names itself in the toolbar (see pageTitle).
        .searchable(text: $app.searchText, placement: .sidebar, prompt: "Search")
        .searchFocused($searchFocused)
        .onChange(of: app.searchFocusRequests) { searchFocused = true }
    }

    @ViewBuilder
    private var detail: some View {
        if let full = app.fullView, let url = app.player.queue.current {
            switch full {
            case .lyrics: FullLyricsView(app: app, url: url)
            case .visualizer: FullVisualizerView(app: app, url: url)
            }
        } else if let library = app.library {
            // Album and artist pages open over the page showing, with Back to return.
            NavigationStack(path: $app.libraryPath) {
                page(library)
                    .navigationDestination(for: LibraryDestination.self) { destination in
                        LibraryDestinationView(app: app, library: library, destination: destination)
                    }
            }
        } else {
            ContentUnavailableView("The library couldn't be opened", systemImage: "externaldrive.badge.exclamationmark",
                                   description: Text("Open files with File › Open… to play them."))
        }
    }

    @ViewBuilder
    private func page(_ library: Library) -> some View {
        if app.isSearching {
            SearchResultsView(app: app, library: library, query: app.searchText)
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
                              title: app.playlists.first { $0.id == id }?.name ?? "Playlist")
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
                //   ... -fullView visualizer   (or lyrics)
                switch defaults.string(forKey: "fullView") {
                case "visualizer": app.fullView = .visualizer
                case "lyrics": app.fullView = .lyrics
                default: break
                }
                if defaults.bool(forKey: "sleepAtEndOfTrack") { app.sleepTimer.stopAtEndOfTrack() }
            }
        }
    }
}

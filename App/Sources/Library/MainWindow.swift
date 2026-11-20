import MiniAmpKit
import os
import SwiftUI
import UniformTypeIdentifiers

struct MainWindow: View {
    @Bindable var app: AppState
    @SceneStorage("sidebarSelection") private var selection: SidebarItem = .home
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if #available(macOS 26, *) {
                // The library runs to the bottom of the window and the bar floats over it, as
                // glass: lists scroll under it, fading out before the window's edge, and leave
                // room after their last row to clear it. Laid over the whole window, not the
                // split view, which slides about as the sidebar opens and closes.
                ZStack(alignment: .bottom) {
                    windowContent(floatingUpNext: true)
                    // Not over full lyrics or the visualizer: their wash runs to the window's edge.
                    if app.fullView == nil { BarFade(height: app.playerBarInset) }
                    // Over the whole window, as the bar is, rather than in the library area:
                    // there, album and artist pages (pushed onto a navigation stack) covered it.
                    if app.showsNowPlaying && app.fullView == nil {
                        upNextPanel
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                    PlayerBar(app: app)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { app.playerBarInset = $0 }
                }
                .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: app.showsNowPlaying)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: app.fullView != nil)
            } else {
                VStack(spacing: 0) {
                    windowContent(floatingUpNext: false)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: app.fullView != nil)
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

    /// Up Next floating over the library's trailing side, as wide as this, inset like the sidebar.
    static let upNextWidth: CGFloat = 300

    /// How much of the library area's trailing side Up Next covers: the panel and its margin
    /// from the window's edge. Pages keep their own margin from it, as from the sidebar.
    private var upNextRoom: CGFloat {
        guard #available(macOS 26, *), app.showsNowPlaying else { return 0 }
        return Self.upNextWidth + Theme.Spacing.s
    }

    /// Up Next, floating at the window's trailing side between the toolbar and the player bar.
    private var upNextPanel: some View {
        NowPlayingView(app: app, floating: true)
            .frame(width: Self.upNextWidth)
            .padding(.top, Theme.Spacing.s)
            .padding(.trailing, Theme.Spacing.s)
            .padding(.bottom, app.playerBarInset + Theme.Spacing.s)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    @ViewBuilder
    private func windowContent(floatingUpNext: Bool) -> some View {
        if let mode = app.fullView, let url = app.player.queue.current {
            FullPlayingView(app: app, url: url, mode: mode)
                .transition(.opacity)
        } else {
            split(floatingUpNext: floatingUpNext)
                .contentMargins(.bottom, app.playerBarInset, for: .scrollContent)
        }
    }

    /// `floatingUpNext`: Up Next as a glass panel over the library (macOS 26 and later), rather
    /// than the inspector, so it floats like the sidebar instead of being a column beside it.
    private func split(floatingUpNext: Bool) -> some View {
        // Read here, in the body: read only inside the binding, SwiftUI doesn't redraw when it
        // changes. Open or closed as it was left, whether or not anything is playing.
        let showsUpNext = app.showsNowPlaying
        return NavigationSplitView {
            Sidebar(app: app, selection: $selection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
        } detail: {
            if floatingUpNext {
                // Up Next floats over the whole window instead (see body).
                detail
            } else {
                detail
                    .inspector(isPresented: Binding(get: { showsUpNext }, set: { app.showsNowPlaying = $0 })) {
                        NowPlayingView(app: app)
                            .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
                    }
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
        if let library = app.library {
            // Album and artist pages open over the page showing, with Back to return.
            NavigationStack(path: $app.libraryPath) {
                // Each page keeps clear of Up Next itself: a page pushed onto the stack doesn't
                // take margins set around the stack.
                page(library)
                    .transition(.opacity)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selection)
                    .clearingUpNext(upNextRoom)
                    .navigationDestination(for: LibraryDestination.self) { destination in
                        LibraryDestinationView(app: app, library: library, destination: destination)
                            .clearingUpNext(upNextRoom)
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

private extension View {
    /// Keeps a page's content clear of Up Next, `room` wide at the trailing side: scroll views
    /// by a content margin, running on under it as under the sidebar; what doesn't scroll by
    /// `clearsUpNext`.
    func clearingUpNext(_ room: CGFloat) -> some View {
        contentMargins(.trailing, room, for: .scrollContent)
            .environment(\.upNextRoom, room)
    }
}

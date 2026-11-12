import MiniAmpKit
import os
import SwiftUI
import UniformTypeIdentifiers

struct MainWindow: View {
    @Bindable var app: AppState
    @SceneStorage("sidebarSelection") private var selection: SidebarItem = .songs
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                Sidebar(app: app, selection: $selection)
                    .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
            } detail: {
                detail
                    .inspector(isPresented: $app.showsNowPlaying) {
                        NowPlayingView(app: app)
                            .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
                    }
            }
            .searchable(text: $app.searchText, placement: .toolbar, prompt: "Songs, artists, albums, genres")
            .searchFocused($searchFocused)
            .onChange(of: app.searchFocusRequests) { searchFocused = true }
            Divider()
            PlayerBar(app: app)
        }
        .frame(minWidth: 860, minHeight: 520)
        .onKeyPress(.space) {
            app.perform { try await app.player.togglePlayPause() }
            return .handled
        }
        .fileImporter(isPresented: $app.importingFiles, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
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
        .onChange(of: selection) { app.showsFullLyrics = false }
        .onChange(of: app.searchText) { if app.isSearching { app.showsFullLyrics = false } }
        .onChange(of: app.player.queue.current == nil) { if app.player.queue.current == nil { app.showsFullLyrics = false } }
        .onChange(of: app.sidebarRequest) {
            guard let item = app.sidebarRequest else { return }
            app.searchText = ""
            selection = item
            app.sidebarRequest = nil
        }
        .sheet(item: $app.editingTags) { target in
            TagEditor(app: app, tracks: target.tracks)
        }
        // Nobody sees the position while the window is hidden or covered; stop redrawing it.
        .onWindowVisibilityChange { app.mainWindowVisible = $0 }
        .task { await start() }
    }

    @ViewBuilder
    private var detail: some View {
        if app.showsFullLyrics, let url = app.player.queue.current {
            FullLyricsView(app: app, url: url)
        } else if let library = app.library, app.isSearching {
            SearchResultsView(app: app, library: library, query: app.searchText)
        } else if let library = app.library {
            switch selection {
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
        } else {
            ContentUnavailableView("The library couldn't be opened", systemImage: "externaldrive.badge.exclamationmark",
                                   description: Text("Open files with File › Open… to play them."))
        }
    }

    private func start() async {
        Logger(subsystem: "dev.miniamp", category: "app").debug("window opened")
        let defaults = UserDefaults.standard
        // Hooks for automated checks: in Debug builds, or in any build when a test database
        // is in use (-libraryDatabase), so a Release check never touches the real library.
        //   miniamp -sidebar albums            (songs, artists, albums, stats, duplicates, or playlist:<id>)
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
                if defaults.bool(forKey: "sleepAtEndOfTrack") { app.sleepTimer.stopAtEndOfTrack() }
            }
        }
    }
}

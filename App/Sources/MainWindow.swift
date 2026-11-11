import MiniAmpKit
import os
import SwiftUI
import UniformTypeIdentifiers

/// What the sidebar can show.
enum SidebarItem: Hashable, RawRepresentable {
    case songs, artists, albums
    case playlist(Int64)

    init?(rawValue: String) {
        switch rawValue {
        case "songs": self = .songs
        case "artists": self = .artists
        case "albums": self = .albums
        default:
            guard rawValue.hasPrefix("playlist:"), let id = Int64(rawValue.dropFirst(9)) else { return nil }
            self = .playlist(id)
        }
    }

    var rawValue: String {
        switch self {
        case .songs: "songs"
        case .artists: "artists"
        case .albums: "albums"
        case .playlist(let id): "playlist:\(id)"
        }
    }
}

struct MainWindow: View {
    @Bindable var app: AppState
    @SceneStorage("sidebarSelection") private var selection: SidebarItem = .songs
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                Sidebar(library: app.library, selection: $selection)
                    .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
            } detail: {
                detail
                    .inspector(isPresented: $app.showsNowPlaying) {
                        NowPlayingView(app: app)
                            .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
                    }
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Toggle(isOn: $app.showsNowPlaying) {
                                Label("Now Playing", systemImage: "music.note.list")
                            }
                            .help("Show the cover and what plays next")
                        }
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
        // Nobody sees the position while the window is hidden or covered; stop redrawing it.
        .onWindowVisibilityChange { app.player.updatesPosition = $0 }
        .task { await start() }
    }

    @ViewBuilder
    private var detail: some View {
        if let library = app.library, app.isSearching {
            SearchResultsView(app: app, library: library, query: app.searchText)
        } else if let library = app.library {
            switch selection {
            case .songs:
                TrackListView(app: app, library: library, scope: .all, title: "Songs")
            case .artists:
                ArtistsView(app: app, library: library)
            case .albums:
                AlbumsView(app: app, library: library)
            case .playlist(let id):
                TrackListView(app: app, library: library, scope: .playlist(id), title: "Playlist")
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
        //   miniamp -sidebar albums            (songs, artists, albums, or playlist:<id>)
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
        #if DEBUG
        // Debug hooks for automated checks:
        //   miniamp -autoplay /path/in/container/file.flac [-hog YES]
        //   miniamp -autoplay '(/path/a.flac, /path/b.flac)' [-sleepAtEndOfTrack YES]
        if let paths = defaults.stringArray(forKey: "autoplay") ?? defaults.string(forKey: "autoplay").map({ [$0] }) {
            if defaults.object(forKey: "hog") != nil { app.player.hogMode = defaults.bool(forKey: "hog") }
            app.perform {
                try await app.player.setQueue(paths.map { URL(fileURLWithPath: $0) })
                if defaults.bool(forKey: "sleepAtEndOfTrack") { app.sleepTimer.stopAtEndOfTrack() }
            }
        }
        #endif
    }
}

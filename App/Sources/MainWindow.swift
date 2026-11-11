import MiniAmpKit
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

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                Sidebar(library: app.library, selection: $selection)
                    .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
            } detail: {
                detail
            }
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
        .task { await start() }
    }

    @ViewBuilder
    private var detail: some View {
        if let library = app.library {
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
        await app.library?.open()
        #if DEBUG
        // Debug hooks for automated checks:
        //   miniamp -libraryFolder /path/in/container
        //   miniamp -autoplay /path/in/container/file.flac [-hog YES]
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: "libraryFolder") {
            app.perform { try await app.library?.addFolder(URL(fileURLWithPath: path, isDirectory: true)) }
        }
        if let path = defaults.string(forKey: "autoplay") {
            if defaults.object(forKey: "hog") != nil { app.player.hogMode = defaults.bool(forKey: "hog") }
            app.perform { try await app.player.setQueue([URL(fileURLWithPath: path)]) }
        }
        #endif
    }
}

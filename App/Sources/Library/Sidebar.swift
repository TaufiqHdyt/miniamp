import MiniAmpKit
import SwiftUI

/// What the sidebar can show.
enum SidebarItem: Hashable, RawRepresentable {
    case home, songs, artists, albums, stats, duplicates
    case playlist(Int64)

    init?(rawValue: String) {
        switch rawValue {
        case "home": self = .home
        case "songs": self = .songs
        case "artists": self = .artists
        case "albums": self = .albums
        case "stats": self = .stats
        case "duplicates": self = .duplicates
        default:
            guard rawValue.hasPrefix("playlist:"), let id = Int64(rawValue.dropFirst(9)) else { return nil }
            self = .playlist(id)
        }
    }

    var title: String {
        switch self {
        case .home: "Home"
        case .songs: "Songs"
        case .albums: "Albums"
        case .artists: "Artists"
        case .stats: "Listening Stats"
        case .duplicates: "Duplicates"
        case .playlist: "Playlist"
        }
    }

    var rawValue: String {
        switch self {
        case .home: "home"
        case .songs: "songs"
        case .artists: "artists"
        case .albums: "albums"
        case .stats: "stats"
        case .duplicates: "duplicates"
        case .playlist(let id): "playlist:\(id)"
        }
    }
}

struct Sidebar: View {
    let app: AppState
    @Binding var selection: SidebarItem
    @State private var deleting: PlaylistSummary?
    private var library: Library? { app.library }

    var body: some View {
        List(selection: Binding(get: { selection }, set: { if let new = $0 { selection = new } })) {
            Section("Library") {
                Label(SidebarItem.songs.title, systemImage: "music.note").tag(SidebarItem.songs)
                Label(SidebarItem.albums.title, systemImage: "square.stack").tag(SidebarItem.albums)
                Label(SidebarItem.artists.title, systemImage: "music.microphone").tag(SidebarItem.artists)
                Label(SidebarItem.home.title, systemImage: "house").tag(SidebarItem.home)
            }
            Section("Library Tools") {
                Label(SidebarItem.stats.title, systemImage: "chart.bar.xaxis").tag(SidebarItem.stats)
                Label(SidebarItem.duplicates.title, systemImage: "square.on.square").tag(SidebarItem.duplicates)
            }
            if library != nil {
                Section {
                    ForEach(app.playlists) { playlist in
                        PlaylistRow(app: app, playlist: playlist)
                            .tag(SidebarItem.playlist(playlist.id))
                            .contextMenu {
                                Button("Play") { app.play(playlist: playlist.id) }
                                Button("Shuffle") { app.play(playlist: playlist.id, shuffled: true) }
                                Button("Play Next") { app.play(playlist: playlist.id, enqueueNext: true) }
                                Button("Play Last") { app.play(playlist: playlist.id, enqueueNext: false) }
                                Divider()
                                Button("Rename") { app.renamingPlaylist = playlist.id }
                                Button("Export as M3U8…") { app.exportPlaylist(playlist) }
                                Divider()
                                Button("Delete Playlist…", role: .destructive) { deleting = playlist }
                            }
                    }
                    // Always last: makes another, by click or by dropping songs on it.
                    NewPlaylistRow(app: app)
                        .selectionDisabled()
                } header: {
                    Text("Playlists")
                }
            }
        }
        .listStyle(.sidebar)
        .focusable(false)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
        .safeAreaInset(edge: .bottom) {
            if let library { LibraryStatus(library: library) { app.run(.addFolder) } }
        }
        .confirmationDialog("Delete the playlist “\(deleting?.name ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                guard let playlist = deleting, let library else { return }
                app.perform { try await library.deletePlaylist(playlist.id) }
            }
        } message: {
            Text("The songs stay in the library.")
        }
    }
}

/// The last row of the playlists: makes one, by click (or ⌘N) or by dropping songs on it.
private struct NewPlaylistRow: View {
    let app: AppState
    @State private var targeted = false

    var body: some View {
        Button { app.newPlaylist() } label: {
            Label("New Playlist", systemImage: "plus.circle")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .foregroundStyle(targeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .help("New Playlist (⌘N). Drop songs here to make one of them.")
        .onDrop(of: [.fileURL], isTargeted: $targeted) { app.dropTracks($0, onPlaylist: nil) }
    }
}

/// A playlist in the sidebar, or a field for its name while it's being renamed.
private struct PlaylistRow: View {
    let app: AppState
    let playlist: PlaylistSummary
    @State private var name = ""
    @FocusState private var focused: Bool
    /// Songs are being dragged over it.
    @State private var targeted = false

    var body: some View {
        if app.renamingPlaylist == playlist.id {
            TextField("Name", text: $name)
                .focused($focused)
                .onAppear {
                    name = playlist.name
                    focused = true
                }
                .onSubmit(commit)
                .onExitCommand { app.renamingPlaylist = nil }
                .onChange(of: focused) { if !focused { commit() } }
        } else {
            Label(playlist.name, systemImage: "music.note.list")
                .badge(playlist.trackCount)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: Theme.Radius.medium)
                        .strokeBorder(.tint, lineWidth: 2)
                        .padding(-3)
                        .opacity(targeted ? 1 : 0)
                }
                .onDrop(of: [.fileURL], isTargeted: $targeted) { app.dropTracks($0, onPlaylist: playlist.id) }
        }
    }

    private func commit() {
        guard app.renamingPlaylist == playlist.id else { return }
        app.renamingPlaylist = nil
        let new = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, new != playlist.name, let library = app.library else { return }
        app.perform { try await library.renamePlaylist(playlist.id, to: new) }
    }
}

/// Track count and scan progress at the foot of the sidebar.
private struct LibraryStatus: View {
    let library: Library
    let addFolder: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                if let progress = library.progress {
                    switch progress.phase {
                    case .listing:
                        ProgressView()
                        Text("Looking for changes…")
                    case .reading, .finished:
                        ProgressView(value: Double(progress.filesRead), total: Double(max(progress.filesToRead, 1)))
                        Text("Reading \(progress.filesRead) of \(progress.filesToRead)")
                    }
                } else if library.folders.isEmpty {
                    Button("Add Music Folder…", action: addFolder)
                        .buttonStyle(.link)
                        .focusable(false)
                } else {
                    Text(CountFormat.songs(library.trackCount))
                        .monospacedDigit()
                }
                if let message = library.lastError {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .help(message)
                }
            }
            .progressViewStyle(.linear)
            .controlSize(.small)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.s)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

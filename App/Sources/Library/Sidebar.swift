import MiniAmpKit
import SwiftUI

/// What the sidebar can show.
enum SidebarItem: Hashable, RawRepresentable {
    case songs, artists, albums, stats, duplicates
    case playlist(Int64)

    init?(rawValue: String) {
        switch rawValue {
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

    var rawValue: String {
        switch self {
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
                Label("Songs", systemImage: "music.note").tag(SidebarItem.songs)
                Label("Artists", systemImage: "music.microphone").tag(SidebarItem.artists)
                Label("Albums", systemImage: "square.stack").tag(SidebarItem.albums)
                Label("Listening Stats", systemImage: "chart.bar.xaxis").tag(SidebarItem.stats)
                Label("Duplicates", systemImage: "square.on.square").tag(SidebarItem.duplicates)
            }
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
                if app.playlists.isEmpty, library != nil {
                    NewPlaylistRow(app: app)
                        .selectionDisabled()
                }
            } header: {
                HStack {
                    Text("Playlists")
                    Spacer()
                    NewPlaylistButton(app: app)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if let library { LibraryStatus(library: library) }
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
        .task(id: library?.revision) {
            await app.reloadPlaylists()
            // A deleted playlist can't stay selected.
            if case .playlist(let id) = selection, !app.playlists.contains(where: { $0.id == id }) { selection = .songs }
        }
    }
}

/// The Playlists header's +: a new playlist; songs dropped on it make one of them.
private struct NewPlaylistButton: View {
    let app: AppState
    @State private var targeted = false

    var body: some View {
        Button { app.newPlaylist() } label: {
            Image(systemName: "plus")
                .fontWeight(.medium)
                .frame(width: 18, height: 18)
                .background(targeted ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.clear), in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("New Playlist (⌘N). Drop songs here to make one of them.")
        .accessibilityLabel("New Playlist")
        .disabled(app.library == nil)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { app.dropTracks($0, onPlaylist: nil) }
    }
}

/// In place of the playlists while there are none: makes one, by click or by dropping songs.
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
        .foregroundStyle(targeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .help("Make a playlist, or drop songs here to make one of them")
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
                    RoundedRectangle(cornerRadius: 5)
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
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let p = library.progress {
                switch p.phase {
                case .listing:
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                    Text("Looking for changes…")
                case .reading, .finished:
                    ProgressView(value: Double(p.filesRead), total: Double(max(p.filesToRead, 1)))
                        .progressViewStyle(.linear).controlSize(.small)
                    Text("Reading \(p.filesRead) of \(p.filesToRead)")
                }
            } else if library.folders.isEmpty {
                Button("Add Music Folder…") { openSettings() }
            } else {
                Text(CountFormat.songs(library.trackCount))
            }
            if let message = library.lastError {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .help(message)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

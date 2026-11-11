import MiniAmpKit
import SwiftUI

struct Sidebar: View {
    let library: Library?
    @Binding var selection: SidebarItem
    @State private var playlists: [PlaylistSummary] = []

    var body: some View {
        List(selection: Binding(get: { selection }, set: { if let new = $0 { selection = new } })) {
            Section("Library") {
                Label("Songs", systemImage: "music.note").tag(SidebarItem.songs)
                Label("Artists", systemImage: "music.microphone").tag(SidebarItem.artists)
                Label("Albums", systemImage: "square.stack").tag(SidebarItem.albums)
            }
            Section("Playlists") {
                ForEach(playlists) { playlist in
                    Label(playlist.name, systemImage: "music.note.list")
                        .badge(playlist.trackCount)
                        .tag(SidebarItem.playlist(playlist.id))
                }
                if playlists.isEmpty {
                    Text("No playlists yet").foregroundStyle(.secondary)
                        .selectionDisabled()
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if let library { LibraryStatus(library: library) }
        }
        .task(id: library?.revision) {
            guard let library else { return }
            playlists = (try? await library.playlists()) ?? []
            // A deleted playlist can't stay selected.
            if case .playlist(let id) = selection, !playlists.contains(where: { $0.id == id }) { selection = .songs }
        }
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
                Text("^[\(library.trackCount) song](inflect: true)")
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

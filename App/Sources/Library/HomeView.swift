import MiniAmpKit
import SwiftUI

/// The first page: shelves of what was added and played lately, this month's most played
/// songs, and albums not heard in a while. All from the library and its play history.
struct HomeView: View {
    let app: AppState
    let library: Library
    @State private var shelves = HomeShelves()
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl - 4) {
                if !shelves.recentlyPlayed.isEmpty {
                    albumShelf("Recently Played", shelves.recentlyPlayed)
                }
                if !shelves.topThisMonth.isEmpty { topThisMonth }
                if !shelves.recentlyAdded.isEmpty {
                    albumShelf("Recently Added", shelves.recentlyAdded, seeAll: { app.sidebarRequest = .albums })
                }
                if !shelves.rediscover.isEmpty {
                    albumShelf("Rediscover", shelves.rediscover)
                }
            }
            .padding(.top, Theme.Spacing.m)
            .padding(.bottom, Theme.Spacing.xl)
        }
        .overlay {
            if loaded && shelves.isEmpty {
                ContentUnavailableView("No Music Yet", systemImage: "music.note.house",
                                       description: Text("Add a music folder with File › Add Music Folder…"))
            }
        }
        .pageTitle("Home")
        .task(id: library.revision) {
            // A scan changes the library many times a second; Home needn't keep up with each.
            if loaded { try? await Task.sleep(for: .seconds(1)) }
            guard !Task.isCancelled else { return }
            if let found = try? await library.home(), found != shelves { shelves = found }
            loaded = true
        }
        // Plays are history, not library changes: read again when the song changes.
        .onChange(of: app.currentURL) {
            Task { if let found = try? await library.home(), found != shelves { shelves = found } }
        }
    }

    private func albumShelf(_ title: String, _ albums: [AlbumSummary], seeAll: (() -> Void)? = nil) -> some View {
        Shelf(title: title, seeAll: seeAll) {
            ForEach(albums) { AlbumLink(app: app, library: library, album: $0) }
        }
    }

    private var topThisMonth: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Top This Month").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                .padding(.horizontal, Theme.Spacing.page)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: Theme.Spacing.l)], spacing: 0) {
                ForEach(shelves.topThisMonth) { info in
                    SongRow(app: app, info: info, leading: .cover, showsArtist: true) {
                        app.play(shelves.topThisMonth, from: info.id)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.page - Theme.Spacing.s)
        }
    }
}

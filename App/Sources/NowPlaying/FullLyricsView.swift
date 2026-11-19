import MiniAmpKit
import SwiftUI

/// The lyrics filling the library area, as in Apple Music: big, over the playing song's
/// cover blurred into a wash of its colours, the song named at the top.
struct FullLyricsView: View {
    let app: AppState
    let url: URL
    @State private var entry: QueueEntry?

    var body: some View {
        let entry = entry?.url == url ? entry : nil
        LyricsView(app: app, url: url, style: .full) {
            FullViewHeading(app: app, entry: entry ?? QueueEntry(fileName: url))
        }
        .id(url)
        .background { CoverWash(app: app, entry: entry) }
        // Light text on the dark wash, whatever the system appearance.
        .environment(\.colorScheme, .dark)
        .fullViewToolbar()
        .modifier(FullViewEntry(app: app, url: url, entry: $entry))
    }
}

/// The playing song's tags, kept up to date with the library (a retagged file).
struct FullViewEntry: ViewModifier {
    let app: AppState
    let url: URL
    @Binding var entry: QueueEntry?

    func body(content: Content) -> some View {
        content.task(id: TagsKey(url: url, revision: app.library?.revision ?? 0)) {
            let loaded = await QueueEntry.load([url], from: app.library)[url]
            if !Task.isCancelled { entry = loaded }
        }
    }

    private struct TagsKey: Equatable {
        var url: URL
        var revision: Int
    }
}

/// The song named at the top of a full view: its cover, title, and artist and album.
struct FullViewHeading: View {
    let app: AppState
    let entry: QueueEntry

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(key: entry.artworkKey, artwork: app.library?.artwork,
                        fileURL: entry.inLibrary ? nil : entry.url, size: .small, cornerRadius: Theme.Radius.medium)
                .frame(width: 64, height: 64)
                .elevation(.floating)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.title2.bold())
                if let subtitle = entry.subtitle {
                    Text(subtitle).font(.title3).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
    }
}

/// A full view's buttons, on glass at the top right, ending in the one back to the library.
struct FullViewControls<Content: View>: View {
    let close: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        let controls = HStack(spacing: 14) {
            content
            Button(action: close) { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Back to the library (Esc)")
        }
        .imageScale(.large)
        .padding(.horizontal, 14)
        .frame(height: 36)
        if #available(macOS 26, *) {
            controls.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            controls.background(.regularMaterial, in: Capsule())
        }
    }
}

extension View {
    /// A full view's chrome: no title in the toolbar (the heading names the song) and the
    /// wash running up under it, as in Apple Music, rather than stopping at a grey bar.
    func fullViewToolbar() -> some View {
        toolbar(removing: .title)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}

/// Behind a full view: the cover, blown up and blurred, darkened so what's on it reads; the
/// cover's colour beneath it, for the moment before it loads (or a song without one).
struct CoverWash: View {
    let app: AppState
    let entry: QueueEntry?

    var body: some View {
        ZStack {
            (app.artworkTint?.color ?? Color(white: 0.18))
            if let entry, entry.artworkKey != nil || !entry.inLibrary {
                GeometryReader { geometry in
                    let side = max(geometry.size.width, geometry.size.height) * 1.2
                    ArtworkView(key: entry.artworkKey, artwork: app.library?.artwork,
                                fileURL: entry.inLibrary ? nil : entry.url, size: .medium, cornerRadius: 0)
                        .frame(width: side, height: side)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                        .blur(radius: 80, opaque: true)
                        .saturation(1.4)
                }
                .transition(.opacity)
            }
            Color.black.opacity(Theme.washDarkness(brightness: app.artworkBrightness))
        }
        .clipped()
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: entry?.artworkKey)
        .accessibilityHidden(true)
    }
}

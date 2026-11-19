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
        LyricsView(app: app, url: url, close: { app.toggleFullLyrics() }) {
            FullViewHeading(app: app, entry: entry ?? QueueEntry(fileName: url))
        }
        .id(url)
        .background { CoverWash(app: app, entry: entry) }
        // Light text on the dark wash, whatever the system appearance.
        .environment(\.colorScheme, .dark)
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

/// The song named in the toolbar over a full view: its cover, title, and artist and album.
struct FullViewHeading: View {
    let app: AppState
    let entry: QueueEntry

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(key: entry.artworkKey, artwork: app.library?.artwork,
                        fileURL: entry.inLibrary ? nil : entry.url, size: .small, cornerRadius: Theme.Radius.small)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.title).font(.headline)
                if let subtitle = entry.subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
        .padding(.horizontal, 4)
        .help([entry.title, entry.subtitle].compactMap { $0 }.joined(separator: "\n"))
    }
}

extension View {
    /// A full view's toolbar: the song where a page's title goes, its buttons and the one
    /// back to the library at the trailing end; the wash running up under it, as in Apple
    /// Music, rather than stopping at a grey bar.
    func fullViewToolbar<Heading: View, Timing: View, Controls: View>(
        close: @escaping () -> Void,
        @ViewBuilder heading: () -> Heading,
        @ViewBuilder timing: () -> Timing = { EmptyView() },
        @ViewBuilder controls: () -> Controls = { EmptyView() }
    ) -> some View {
        let heading = heading()
        let timing = timing()
        let controls = controls()
        return toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .navigation) { heading }
                    .fullViewHeadingBackground()
                // Pushes what follows to the window's trailing edge, away from the song.
                FullViewSpacer(flexible: true)
                // On a glass of its own, apart from the buttons about the words.
                ToolbarItem(placement: .automatic) { timing }
                FullViewSpacer(flexible: false)
                ToolbarItemGroup(placement: .automatic) { controls }
                // Back to the library on a glass of its own, apart from the page's buttons.
                FullViewSpacer(flexible: false)
                ToolbarItem(placement: .automatic) {
                    Button(action: close) { Label("Back to the Library", systemImage: "arrow.down.right.and.arrow.up.left") }
                        .keyboardShortcut(.cancelAction)
                        .help("Back to the library (Esc)")
                }
            }
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}

/// A toolbar spacer on macOS 26 and later, where toolbar items sit on glass; nothing before.
private struct FullViewSpacer: ToolbarContent {
    let flexible: Bool

    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarSpacer(flexible ? .flexible : .fixed, placement: .automatic)
        }
    }
}

private extension ToolbarContent {
    /// The song sits on the wash, not on a glass button.
    @ToolbarContentBuilder
    func fullViewHeadingBackground() -> some ToolbarContent {
        if #available(macOS 26, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
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

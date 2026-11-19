import MiniAmpKit
import SwiftUI

/// Now Playing with the lyrics, as in Apple Music: big, beside the playing song's cover, over
/// the cover blurred into a wash of its colours.
struct FullLyricsView: View {
    let app: AppState
    let url: URL
    @State private var entry: QueueEntry?

    var body: some View {
        let entry = entry?.url == url ? entry : nil
        NowPlayingLayout(app: app, entry: entry) {
            LyricsView(app: app, url: url)
                .id(url)
        }
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
            if entry?.url != url, let known = app.upNextEntries[url] { entry = known }
            let loaded = await QueueEntry.load([url], from: app.library)[url]
            if !Task.isCancelled, let loaded { entry = loaded }
        }
    }

    private struct TagsKey: Equatable {
        var url: URL
        var revision: Int
    }
}

extension View {
    /// A full view's toolbar: back to the library where a pushed page's Back is, a switch
    /// between lyrics and the visualizer in the middle, the page's buttons at the trailing
    /// end. Not the song: the player bar under the page names it (and opens its album and
    /// artist). The wash runs up under the toolbar, as in Apple Music, rather than stopping at
    /// a grey bar.
    func fullViewToolbar<Timing: View, Controls: View>(
        app: AppState,
        @ViewBuilder timing: () -> Timing = { EmptyView() },
        @ViewBuilder controls: () -> Controls = { EmptyView() }
    ) -> some View {
        let timing = timing()
        let controls = controls()
        return toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { app.showFullView(nil) } label: { Label("Back to the Library", systemImage: "chevron.left") }
                        .keyboardShortcut(.cancelAction)
                        .help("Back to the library (Esc)")
                }
                ToolbarItem(placement: .principal) {
                    Picker("Show", selection: Binding(get: { app.fullView ?? .lyrics }, set: { app.showFullView($0) })) {
                        ForEach(FullView.allCases, id: \.self) { view in
                            Label(view.label, systemImage: view.symbol).tag(view)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelStyle(.titleAndIcon)
                    .fixedSize()
                    .help("Lyrics (⌥⌘L) or the visualizer (⇧⌥⌘V)")
                }
                ToolbarItem(placement: .automatic) { timing }
                // On a glass of its own, apart from the timing.
                FullViewSpacer(flexible: false)
                ToolbarItemGroup(placement: .automatic) { controls }
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

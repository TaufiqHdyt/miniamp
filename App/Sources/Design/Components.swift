import MiniAmpKit
import SwiftUI

// Pieces the pages share. See Theme for the values they use.

extension View {
    /// A page's name in the toolbar, its count under it, and the page's own controls at the
    /// toolbar's trailing end (as in Finder and Mail).
    func pageTitle(_ title: String, subtitle: String = "") -> some View {
        navigationTitle(title).navigationSubtitle(subtitle)
    }

    func pageTitle(_ title: String, subtitle: String = "", @ViewBuilder controls: () -> some View) -> some View {
        let controls = controls()
        return pageTitle(title, subtitle: subtitle)
            .toolbar { ToolbarItem(placement: .primaryAction) { controls } }
    }
}

/// A cover with a title and a line under it (an album and its artist). Hovering dims the cover a little and shows a
/// play button on it, as in Apple Music; clicking elsewhere opens it.
struct ArtworkTile: View {
    let title: String
    let subtitle: String
    let artworkKey: String?
    let artwork: ArtworkCache?
    let play: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ArtworkView(key: artworkKey, artwork: artwork, cornerRadius: Theme.Radius.medium)
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(.black.opacity(hovering ? 0.18 : 0))
                }
                .overlay(alignment: .bottomLeading) {
                    if hovering {
                        Button(action: play) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(.black.opacity(0.55), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                        .help("Play \(title)")
                        .transition(.opacity)
                    }
                }
                .elevation(hovering ? .lifted : .tile)
            Text(title).font(.callout.weight(.semibold)).lineLimit(1).padding(.top, Theme.Spacing.xs)
            Text(subtitle).lineLimit(1).font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A headline number with its label, in Listening Stats.
struct StatCard: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.callout).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.m)
        .panelSurface()
    }
}

/// Play and Shuffle, side by side, under a header (an album, a playlist).
struct PlayShuffleButtons: View {
    let play: () -> Void
    let shuffle: () -> Void

    var body: some View {
        HStack {
            Button(action: play) { Label("Play", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            Button(action: shuffle) { Label("Shuffle", systemImage: "shuffle") }
        }
    }
}

/// A titled row of things that scrolls sideways (albums on Home, More by This Artist).
struct Shelf<Content: View>: View {
    let title: String
    var seeAll: (() -> Void)? = nil
    /// What's on the shelf, in order: when it changes (Recently Played, after each song), the
    /// shelf goes back to its start, rather than keep an offset that cuts the first cover.
    var contents: [AnyHashable] = []
    @ViewBuilder var content: Content
    @State private var position = ScrollPosition(edge: .leading)
    @Environment(\.upNextRoom) private var upNextRoom

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                if let seeAll {
                    Button("See All", action: seeAll).buttonStyle(.link)
                }
            }
            .padding(.horizontal, Theme.Spacing.page)
            .clearsUpNext()
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Theme.Spacing.l) { content }
                    .padding(.horizontal, Theme.Spacing.page)
                    .padding(.top, Theme.Spacing.xs)
                    // Room for the scroller below the names, not over them.
                    .padding(.bottom, Theme.Spacing.m)
            }
            .scrollPosition($position)
            .onChange(of: contents) { position.scrollTo(edge: .leading) }
            .scrollIndicators(.automatic)
            // Out under Up Next (the page runs to the window's edge, see `runsUnderUpNext`),
            // the last cover clear of it; not out under the sidebar.
            .contentMargins(.trailing, upNextRoom, for: .scrollContent)
            .clipped()
        }
    }
}

/// The top of an album or artist page: the cover large, over a blur of it that fades into
/// the page, with the title, what it is, a line of details, and Play and Shuffle.
struct HeroHeader<Artwork: View, Actions: View>: View {
    /// "Album", "Single", "Artist".
    let kind: String
    let title: String
    var subtitle: String? = nil
    var openSubtitle: (() -> Void)? = nil
    let details: String
    let washKey: String?
    let artwork: ArtworkCache?
    @ViewBuilder var cover: Artwork
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.l + 4) {
            cover
                .frame(width: 200, height: 200)
                .elevation(.floating)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(kind)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 36, weight: .bold))
                    .tracking(-0.8)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    if let openSubtitle {
                        Button(action: openSubtitle) { Text(subtitle) }
                            .buttonStyle(.plain)
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .help("Go to \(subtitle)")
                    } else {
                        Text(subtitle).font(.title3).foregroundStyle(.secondary)
                    }
                }
                Text(details).font(.callout).foregroundStyle(.secondary)
                actions.padding(.top, Theme.Spacing.s)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.top, Theme.Spacing.m)
        .padding(.bottom, Theme.Spacing.xl)
        .background { HeroWash(key: washKey, artwork: artwork) }
    }
}

/// A blur of the cover behind a header, fading into the page toward the bottom. It reaches
/// up past the header, under the toolbar (which the page scrolls beneath), so no white strip
/// shows there.
private struct HeroWash: View {
    /// More than any toolbar is tall.
    static let reach: CGFloat = 120
    let key: String?
    let artwork: ArtworkCache?

    var body: some View {
        if let key {
            GeometryReader { geometry in
                ArtworkView(key: key, artwork: artwork, size: .small, cornerRadius: 0)
                    .frame(width: geometry.size.width, height: geometry.size.width)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    .blur(radius: 60, opaque: true)
                    .saturation(1.3)
                    .opacity(0.45)
            }
            .overlay {
                Rectangle().fill(.background)
                    .mask { LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom) }
            }
            .clipped()
            .padding(.top, -HeroWash.reach)
            .accessibilityHidden(true)
        }
    }
}

/// Up to four covers in a square, standing for an artist.
struct CoverMosaic: View {
    let keys: [String]
    let artwork: ArtworkCache?

    var body: some View {
        Group {
            if keys.count >= 4 {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow { tile(keys[0]); tile(keys[1]) }
                    GridRow { tile(keys[2]); tile(keys[3]) }
                }
            } else {
                tile(keys.first)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
    }

    private func tile(_ key: String?) -> some View {
        ArtworkView(key: key, artwork: artwork, size: .medium, cornerRadius: 0)
    }
}

extension EnvironmentValues {
    /// How much of the library area's trailing side Up Next covers (floating, macOS 26 and
    /// later), panel and margins; 0 while it's closed. Scroll views keep their content clear
    /// of it by a content margin and run on under it; see `clearsUpNext` for what isn't a
    /// scroll view, and `runsUnderUpNext` for pages of shelves.
    @Entry var upNextRoom: CGFloat = 0
}

extension View {
    /// Keeps clear of Up Next: for what doesn't scroll, or (tables, lists) ignores content margins.
    func clearsUpNext() -> some View { modifier(UpNextRoom()) }

    /// A page with shelves: its scroll view's content runs to the window's edge, under Up
    /// Next, so the shelves can; all else on it clears Up Next itself (`clearsUpNext`). Not
    /// the shelves widened past the page instead: a shelf so widened came up scrolled
    /// partway, its first cover cut.
    func runsUnderUpNext() -> some View { contentMargins(.trailing, 0, for: .scrollContent) }
}

private struct UpNextRoom: ViewModifier {
    @Environment(\.upNextRoom) private var room

    func body(content: Content) -> some View {
        content.padding(.trailing, room)
    }
}

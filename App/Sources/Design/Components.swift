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
            Text(title).lineLimit(1).padding(.top, 3)
            Text(subtitle).lineLimit(1).font(.callout).foregroundStyle(.secondary)
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
            Text(value).font(.title2.bold().monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.callout).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.m)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Radius.large))
    }
}

/// Play and Shuffle, side by side, under a header (an album, a playlist).
struct PlayShuffleButtons: View {
    let play: () -> Void
    let shuffle: () -> Void

    var body: some View {
        HStack {
            Button(action: play) { Label("Play", systemImage: "play.fill") }
                .keyboardShortcut(.defaultAction)
            Button(action: shuffle) { Label("Shuffle", systemImage: "shuffle") }
        }
    }
}

/// A titled row of things that scrolls sideways (albums on Home, More by This Artist).
struct Shelf<Content: View>: View {
    let title: String
    var seeAll: (() -> Void)? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                if let seeAll {
                    Button("See All", action: seeAll).buttonStyle(.link)
                }
            }
            .padding(.horizontal, Theme.Spacing.page)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Theme.Spacing.l) { content }
                    .padding(.horizontal, Theme.Spacing.page)
                    .padding(.vertical, Theme.Spacing.xs)
            }
            .scrollIndicators(.automatic)
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
    /// Room above for the toolbar, which the header's blur runs under.
    var toolbarHeight: CGFloat = 0
    @ViewBuilder var cover: Artwork
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.l + 4) {
            cover
                .frame(width: 200, height: 200)
                .elevation(.floating)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(kind.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 34, weight: .bold))
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
        .padding(.top, toolbarHeight + Theme.Spacing.m)
        .padding(.bottom, Theme.Spacing.l)
        .background { HeroWash(key: washKey, artwork: artwork) }
    }
}

/// A blur of the cover behind a header, fading into the page toward the bottom.
private struct HeroWash: View {
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

/// A page whose top runs up under the toolbar (an album's or artist's header and its blur),
/// rather than starting below it on a white strip. `content` gets the toolbar's height, to
/// keep what matters below it.
struct UnderToolbarScrollView<Content: View>: View {
    @ViewBuilder var content: (_ toolbarHeight: CGFloat) -> Content
    @State private var toolbarHeight: CGFloat = 52

    var body: some View {
        ScrollView { content(toolbarHeight) }
            .ignoresSafeArea(edges: .top)
            .background {
                Color.clear.onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { toolbarHeight = $0 }
            }
    }
}

import MiniAmpKit
import SwiftUI

// Pieces the pages share. See Theme for the values they use.

extension View {
    /// Keep page counts and controls below the fixed navigation title.
    func pageSummary(_ subtitle: String) -> some View {
        pageSummary(subtitle) { EmptyView() }
    }

    func pageSummary(_ subtitle: String = "", @ViewBuilder controls: () -> some View) -> some View {
        let controls = controls()
        return VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.m) {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityHidden(subtitle.isEmpty)
                Spacer(minLength: 0)
                controls
            }
            .frame(minHeight: 36)
            .padding(.horizontal, Theme.Spacing.m)
            Divider()
            self.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func lyricsTextEditorStyle() -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.medium)
        return font(.system(.body, design: .monospaced))
            .accessibilityLabel("Lyrics Text")
            .autocorrectionDisabled()
            .scrollContentBackground(.hidden)
            .padding(Theme.Spacing.xs)
            .background(Color(nsColor: .textBackgroundColor), in: shape)
            .overlay { shape.strokeBorder(.quaternary).allowsHitTesting(false) }
    }

}

extension ToolbarContent {
    @ToolbarContentBuilder
    func withoutSharedBackground() -> some ToolbarContent {
        if #available(macOS 26, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                        .accessibilityLabel("Play \(title)")
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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
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
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Theme.Spacing.l) { content }
                    .padding(.horizontal, Theme.Spacing.page)
                    .padding(.top, Theme.Spacing.xs)
                    // Room for the scroller below the names, not over them.
                    .padding(.bottom, Theme.Spacing.m)
            }
            .scrollPosition($position)
            .focusable(false)
            .accessibilityLabel(title)
            .onChange(of: contents) { position.scrollTo(edge: .leading) }
            .scrollIndicators(.automatic)
            .clipped()
        }
    }
}

/// An album or artist header with artwork, details, and playback actions.
struct HeroHeader<Artwork: View, Actions: View>: View {
    /// "Album", "Single", "Artist".
    let kind: String
    let title: String
    var subtitle: String? = nil
    var openSubtitle: (() -> Void)? = nil
    let details: String
    @ViewBuilder var cover: Artwork
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.l + 4) {
            cover
                .frame(width: 200, height: 200)
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

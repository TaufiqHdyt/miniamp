import MiniAmpKit
import SwiftUI

// Pieces the pages share. See Theme for the values they use.

/// A page's name, large at the top of the page as in Apple Music, its count beside it, and
/// the page's own controls at the trailing edge. (The toolbar carries no title.)
struct PageHeader<Accessory: View>: View {
    let title: String
    var subtitle = ""
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(.largeTitle.bold())
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityAddTraits(.isHeader)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
            }
            Spacer(minLength: Theme.Spacing.m)
            accessory
        }
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.top, Theme.Spacing.xs)
        .padding(.bottom, Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension PageHeader where Accessory == EmptyView {
    init(title: String, subtitle: String = "") {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
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

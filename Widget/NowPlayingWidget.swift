import AppIntents
import SwiftUI
import WidgetKit

@main
struct MiniAmpWidgets: WidgetBundle {
    var body: some Widget { NowPlayingWidget() }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedContainer.widgetKind, provider: Provider()) { entry in
            NowPlayingWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Now Playing")
        .description("What miniamp is playing, with play, pause, and skip.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct Entry: TimelineEntry {
    var date: Date
    var snapshot: NowPlayingSnapshot
    var artwork: NSImage?
}

/// One entry, from what the app last wrote; the app asks for a reload when it changes.
struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, snapshot: NowPlayingSnapshot(title: "Song Title", artist: "Artist", isPlaying: true,
                                                       position: 60, positionDate: .now, duration: 200))
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let entry = current()
        // Once the song would be over, show it as stopped until the app says otherwise.
        let end = entry.snapshot.isPlaying ? entry.snapshot.startDate.addingTimeInterval(entry.snapshot.duration) : nil
        completion(Timeline(entries: [entry], policy: end.map { .after(max($0, .now.addingTimeInterval(60))) } ?? .never))
    }

    private func current() -> Entry {
        var snapshot = SharedContainer.readSnapshot() ?? .empty
        if snapshot.isPlaying, snapshot.startDate.addingTimeInterval(snapshot.duration) < .now { snapshot.isPlaying = false }
        let artwork = snapshot.artworkID == nil ? nil : SharedContainer.artworkURL.flatMap { NSImage(contentsOf: $0) }
        return Entry(date: .now, snapshot: snapshot, artwork: artwork)
    }
}

struct NowPlayingWidgetView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let s = entry.snapshot
        switch family {
        case .systemSmall:
            VStack(alignment: .leading, spacing: 6) {
                cover.frame(width: 56, height: 56)
                Spacer(minLength: 0)
                titles(s)
                progress(s)
            }
        default:
            HStack(spacing: 14) {
                cover.frame(maxHeight: .infinity).aspectRatio(1, contentMode: .fit)
                VStack(alignment: .leading, spacing: 8) {
                    titles(s)
                    Spacer(minLength: 0)
                    progress(s)
                    HStack(spacing: 22) {
                        Button(intent: PreviousTrackIntent()) { Image(systemName: "backward.fill") }
                        Button(intent: TogglePlaybackIntent()) {
                            Image(systemName: s.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                        }
                        Button(intent: NextTrackIntent()) { Image(systemName: "forward.fill") }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private var cover: some View {
        if let artwork = entry.artwork {
            Image(nsImage: artwork).resizable().scaledToFill().clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                .overlay { Image(systemName: "music.note").font(.title).foregroundStyle(.secondary) }
        }
    }

    private func titles(_ s: NowPlayingSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(s.title).font(.headline).lineLimit(1)
            if let artist = s.artist { Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
    }

    @ViewBuilder
    private func progress(_ s: NowPlayingSnapshot) -> some View {
        if s.duration > 0 {
            if s.isPlaying {
                ProgressView(timerInterval: s.startDate...s.startDate.addingTimeInterval(s.duration), countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
            } else {
                ProgressView(value: min(s.position / s.duration, 1))
            }
        }
    }
}

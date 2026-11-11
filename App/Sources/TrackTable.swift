import AppKit
import MiniAmpKit
import SwiftUI

/// The tracks in a scope, reloaded whenever the library changes.
struct TrackListView: View {
    let app: AppState
    let library: Library
    let scope: TrackScope
    let title: String
    @State private var tracks: [TrackInfo] = []
    @State private var loaded = false

    var body: some View {
        TrackTable(app: app, tracks: tracks, inPlaylist: { if case .playlist = scope { true } else { false } }())
            .overlay {
                if loaded && tracks.isEmpty {
                    ContentUnavailableView(library.folders.isEmpty ? "No music yet" : "Nothing here",
                                           systemImage: "music.note",
                                           description: Text(library.folders.isEmpty
                                               ? "Add a music folder in Settings."
                                               : "No tracks match."))
                }
            }
            .navigationTitle(title)
            .navigationSubtitle(tracks.isEmpty ? "" : "\(tracks.count) songs")
            .task(id: TrackQuery(scope: scope, revision: library.revision)) {
                await load()
            }
    }

    private func load() async {
        // A scan commits in batches; let a burst of changes settle before reloading.
        if loaded { try? await Task.sleep(for: .milliseconds(250)) }
        guard !Task.isCancelled else { return }
        do {
            let found = try await library.tracks(in: scope)
            guard !Task.isCancelled else { return }
            tracks = found
            loaded = true
        } catch {
            app.error = "\(error)"
        }
    }
}

private struct TrackQuery: Equatable {
    var scope: TrackScope
    var revision: Int
}

/// A table of tracks. Double-click (or Return) plays the list from that row.
struct TrackTable: View {
    let app: AppState
    let tracks: [TrackInfo]
    var inPlaylist = false
    @State private var selection: Set<TrackInfo.ID> = []

    var body: some View {
        Table(tracks, selection: $selection) {
            TableColumn("#") { info in
                Text(info.track.trackNumber.map(String.init) ?? "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 24, ideal: 30, max: 50)
            TableColumn("Title") { info in
                TitleCell(app: app, info: info)
            }
            .width(min: 120, ideal: 260)
            TableColumn("Artist") { info in Text(info.artistName ?? "") }
                .width(min: 80, ideal: 160)
            TableColumn("Album") { info in Text(info.albumTitle ?? "") }
                .width(min: 80, ideal: 180)
            TableColumn("Time") { info in
                Text(TimeFormat.minutes(info.track.durationMs / 1000))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 40, ideal: 50, max: 70)
            TableColumn("Quality") { info in
                QualityCell(info: info, isDownloading: app.isWaitingToPlay(info.id))
            }
            .width(min: 70, ideal: 110, max: 160)
        }
        .contextMenu(forSelectionType: TrackInfo.ID.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            app.play(tracks, from: ids.first)
        }
    }

    @ViewBuilder
    private func menu(for ids: Set<TrackInfo.ID>) -> some View {
        let chosen = tracks.filter { ids.contains($0.id) }
        if !chosen.isEmpty {
            Button("Play") { app.play(chosen.count > 1 ? chosen : tracks, from: chosen.first?.id) }
            Button("Shuffle") { app.play(chosen.count > 1 ? chosen : tracks, from: nil, shuffled: true) }
            Divider()
            if chosen.contains(where: \.track.isEvicted) {
                Button("Download from iCloud") { app.library?.download(chosen.map(\.track)) }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(chosen.map(\.track.url))
            }
        }
    }
}

/// The title, with a speaker on the track that's playing.
private struct TitleCell: View {
    let app: AppState
    let info: TrackInfo

    var body: some View {
        HStack(spacing: 4) {
            if app.currentURL == info.track.url {
                Image(systemName: app.player.state == .playing ? "speaker.wave.2.fill" : "speaker.fill")
                    .foregroundStyle(.tint)
                    .imageScale(.small)
            }
            Text(info.track.title)
        }
    }
}

private struct QualityCell: View {
    let info: TrackInfo
    let isDownloading: Bool

    var body: some View {
        if isDownloading {
            ProgressView().controlSize(.mini).help("Downloading from iCloud; plays when it's ready")
        } else if info.track.isEvicted {
            Label("In iCloud", systemImage: "icloud")
                .foregroundStyle(.secondary)
                .help("Not downloaded. Double-click to download and play.")
        } else {
            Text(TrackFormat.short(info.track))
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}

enum TrackFormat {
    /// "FLAC 96/24", "MP3 320k".
    static func short(_ track: Track) -> String {
        short(codec: track.codec, sampleRate: track.sampleRate, bits: track.bitsPerSample, bitrateKbps: track.bitrateKbps)
    }

    static func short(codec: String, sampleRate: Int, bits: Int?, bitrateKbps: Int) -> String {
        guard sampleRate > 0 else { return codec }
        let khz = Double(sampleRate) / 1000
        let rate = khz == khz.rounded() ? "\(Int(khz))" : String(format: "%.1f", khz)
        if let bits { return "\(codec) \(rate)/\(bits)" }
        return bitrateKbps > 0 ? "\(codec) \(bitrateKbps)k" : "\(codec) \(rate)"
    }
}

enum TimeFormat {
    /// "3:07", "1:02:03".
    static func minutes(_ seconds: Int) -> String {
        let s = max(seconds, 0)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

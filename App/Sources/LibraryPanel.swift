import MiniAmpKit
import SwiftUI

/// M3 test bench for the library: folders, scan progress, and search. The real browser is M4.
struct LibraryPanel: View {
    let library: Library
    let player: Player
    @Binding var error: String?
    @State private var choosingFolder = false
    @State private var query = ""
    @State private var results: [TrackInfo] = []
    /// An offloaded track that was double-clicked: it plays once it's downloaded.
    @State private var waitingToPlay: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Library").font(.headline)
                Text("\(library.trackCount) tracks").foregroundStyle(.secondary)
                Spacer()
                Button("Add Folder…") { choosingFolder = true }
                Button("Rescan") { library.rescan() }.disabled(library.folders.isEmpty)
            }
            ForEach(library.folders) { folder in
                HStack {
                    Image(systemName: "folder")
                    Text(folder.path).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { remove(folder) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove from library (files stay on disk)")
                }
                .font(.callout)
            }
            if let p = library.progress {
                ScanProgressView(progress: p)
            } else if let scan = library.lastScan {
                Text("Last scan: \(scan.filesFound) files, \(scan.added) added, \(scan.updated) updated, \(scan.moved) moved, \(scan.removed) removed\(scan.offloaded > 0 ? ", \(scan.offloaded) in iCloud" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = library.lastError {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
            }

            TextField("Search titles, artists, albums, genres", text: $query)
                .textFieldStyle(.roundedBorder)
            List(Array(results.enumerated()), id: \.element.id) { index, info in
                TrackRow(info: info, artwork: library.artwork, isDownloading: waitingToPlay == info.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { play(from: index) }
            }
            .listStyle(.bordered)
        }
        .frame(minWidth: 380)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): Task { do { try await library.addFolder(url) } catch let e { error = "\(e)" } }
            case .failure(let e): error = e.localizedDescription
            }
        }
        // Re-query when the text changes (after a short pause) or the library does.
        .task(id: "\(query)\u{0}\(library.revision)") {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            do {
                let found = query.trimmingCharacters(in: .whitespaces).isEmpty
                    ? try await library.allTracks(limit: 500)
                    : try await library.search(query, limit: 500)
                if !Task.isCancelled {
                    results = found
                    playIfDownloaded()
                }
            } catch let e {
                error = "\(e)"
            }
        }
    }

    /// Queues the list from `index`. Offloaded tracks are left out of the queue (opening one would
    /// wait on a download mid-playback); double-clicking one downloads it, then plays it.
    private func play(from index: Int) {
        let target = results[index]
        if target.track.isEvicted {
            waitingToPlay = target.id
            library.download([target.track])
            return
        }
        waitingToPlay = nil
        let playable = results.filter { !$0.track.isEvicted }
        guard let start = playable.firstIndex(where: { $0.id == target.id }) else { return }
        Task { do { try await player.setQueue(playable.map(\.track.url), startAt: start) } catch let e { error = "\(e)" } }
    }

    private func playIfDownloaded() {
        guard let id = waitingToPlay, let index = results.firstIndex(where: { $0.id == id }),
              !results[index].track.isEvicted
        else { return }
        play(from: index)
    }

    private func remove(_ folder: LibraryFolder) {
        Task { do { try await library.removeFolder(folder) } catch let e { error = "\(e)" } }
    }
}

private struct ScanProgressView: View {
    let progress: ScanProgress

    var body: some View {
        switch progress.phase {
        case .listing:
            ProgressView { Text("Looking for changes…").font(.caption) }.progressViewStyle(.linear)
        case .reading, .finished:
            ProgressView(value: Double(progress.filesRead), total: Double(max(progress.filesToRead, 1))) {
                Text("Reading tags: \(progress.filesRead) of \(progress.filesToRead)").font(.caption)
            }
        }
    }
}

private struct TrackRow: View {
    let info: TrackInfo
    let artwork: ArtworkCache?
    let isDownloading: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let key = info.track.artworkKey, let artwork {
                    AsyncImage(url: artwork.thumbnailURL(for: key)) { image in
                        image.resizable().scaledToFill()
                    } placeholder: { Color.secondary.opacity(0.15) }
                } else {
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 1) {
                Text(info.track.title).lineLimit(1)
                Text([info.artistName, info.albumTitle].compactMap { $0 }.joined(separator: " — "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if isDownloading {
                ProgressView().controlSize(.small).help("Downloading from iCloud; plays when it's ready")
            } else if info.track.isEvicted {
                Image(systemName: "icloud").foregroundStyle(.secondary)
                    .help("Not downloaded. Double-click to download and play.")
            } else {
                Text(quality).font(.caption).monospaced().foregroundStyle(.secondary)
            }
        }
    }

    private var quality: String {
        let rate = FormatSelection.formatRate(Double(info.track.sampleRate))
        let bits = info.track.bitsPerSample.map { "/\($0)" } ?? ""
        return "\(info.track.codec) \(rate)\(bits)"
    }
}

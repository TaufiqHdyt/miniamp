import MiniAmpKit
import SwiftUI

/// The Lyrics pane: laid out like Up Next, the song playing first, then its lyrics where the
/// queue would be. Synced lyrics follow playback, the line being sung kept in view (and, in
/// word-timed lyrics, its words lit as they're sung); clicking a line plays from there.
struct LyricsView<NowPlaying: View>: View {
    let app: AppState
    let url: URL
    /// The Now Playing row, as Up Next shows it.
    @ViewBuilder let nowPlaying: NowPlaying

    @State private var state: LoadState = .loading
    @State private var follower: LyricsFollower?

    enum LoadState: Equatable {
        case loading
        case searching
        case found(FoundLyrics)
        case none(searchedOnline: Bool)
        case failed(String)
    }

    private struct LoadKey: Equatable {
        var url: URL
        var online: Bool
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section("Now Playing") { nowPlaying }
                Section {
                    rows
                } header: {
                    HStack {
                        Text("Lyrics")
                        Spacer()
                        if case .found(let found) = state, found.lyrics.isSynced { TimingControl(app: app, url: url) }
                    }
                } footer: {
                    if case .found(let found) = state, !found.lyrics.isInstrumental {
                        Text(sourceLabel(found.source)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)
            .onChange(of: follower?.position.line) { scroll(proxy, animated: true) }
            .onChange(of: state) { scroll(proxy, animated: false) }
        }
        .task(id: LoadKey(url: url, online: app.looksUpLyricsOnline)) {
            if follower == nil { follower = LyricsFollower(player: app.player) }
            await app.loadLyricsOffset(for: url)
            follower?.offset = app.totalLyricsOffset(for: url)
            await load(app.looksUpLyricsOnline ? .automatic : .cachedOnly)
        }
        .onChange(of: app.totalLyricsOffset(for: url)) { follower?.offset = app.totalLyricsOffset(for: url) }
    }

    @ViewBuilder
    private var rows: some View {
        switch state {
        case .loading:
            EmptyView()
        case .searching:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Searching LRCLIB…").foregroundStyle(.secondary)
            }
        case .found(let found) where found.lyrics.isInstrumental:
            Label("Instrumental: LRCLIB says this song has no words.", systemImage: "pianokeys")
                .foregroundStyle(.secondary)
        case .found(let found):
            if found.lyrics.isSynced, let follower {
                ForEach(found.lyrics.lines) { line in
                    LyricLine(line: line, position: follower.position)
                        .contentShape(Rectangle())
                        .onTapGesture { if let time = line.time { app.player.seek(to: follower.playbackTime(for: time)) } }
                        .listRowSeparator(.hidden)
                }
            } else {
                Text(found.lyrics.lines.map(\.text).joined(separator: "\n"))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowSeparator(.hidden)
            }
        case .none(let searched):
            VStack(alignment: .leading, spacing: 8) {
                Text(searched
                     ? "No lyrics in the file, beside it, or on LRCLIB."
                     : "No lyrics in the file or in a .lrc file beside it.")
                    .foregroundStyle(.secondary)
                Button(searched ? "Search LRCLIB Again" : "Search LRCLIB") { Task { await load(.refresh) } }
                    .help("Sends this song's title, artist, album, and duration to lrclib.net")
            }
            .padding(.vertical, 4)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Couldn't get lyrics: \(message)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Button("Try Again") { Task { await load(.refresh) } }
            }
            .padding(.vertical, 4)
        }
    }

    /// Keeps the line being sung a third of the way down.
    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard case .found(let found) = state, found.lyrics.isSynced, let line = follower?.position.line else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(line, anchor: UnitPoint(x: 0.5, y: 0.35)) }
        } else {
            proxy.scrollTo(line, anchor: UnitPoint(x: 0.5, y: 0.35))
        }
    }

    private func load(_ online: LyricsFinder.Online) async {
        let wanted = url
        if online == .refresh { state = .searching }
        do {
            var result = try await app.lyricsFinder.find(for: wanted, online: online == .automatic ? .cachedOnly : online)
            // Show what's local or cached at once; only then wait on the network.
            if online == .automatic, case .notFound(searchedOnline: false) = result {
                state = .searching
                result = try await app.lyricsFinder.find(for: wanted, online: .automatic)
            }
            guard !Task.isCancelled, wanted == url else { return }
            switch result {
            case .found(let found):
                state = .found(found)
                follower?.lyrics = found.lyrics
            case .notFound(let searched):
                state = .none(searchedOnline: searched)
                follower?.lyrics = nil
            }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch is LyricsFinder.MissingTags where online == .automatic {
            // Nothing to search by; not worth an error unless the search was asked for.
            if wanted == url { state = .none(searchedOnline: false) }
        } catch {
            guard wanted == url else { return }
            follower?.lyrics = nil
            state = .failed("\(error)")
        }
    }

    private func sourceLabel(_ source: FoundLyrics.Source) -> String {
        switch source {
        case .sidecar(let file): "From \(file.lastPathComponent)"
        case .embedded: "From the file's tags"
        case .lrclib: "From LRCLIB"
        }
    }
}

/// Nudges one song's lyrics sooner or later, 0.1 s a click; the readout resets it.
private struct TimingControl: View {
    let app: AppState
    let url: URL

    var body: some View {
        let offset = app.lyricsOffset(for: url)
        HStack(spacing: 2) {
            Button { app.adjustLyricsTiming(by: .zero - AppState.lyricsStep) } label: { Image(systemName: "minus") }
                .help("Show the lyrics later (⌥⌘])")
            Button(Self.label(offset)) { app.adjustLyricsTiming(by: nil) }
                .monospacedDigit()
                .frame(minWidth: 64)
                .disabled(offset == .zero)
                .help(offset == .zero ? "Use − and + if the lyrics are out of step with this song"
                                      : "Click to put this song's lyrics back as they were")
            Button { app.adjustLyricsTiming(by: AppState.lyricsStep) } label: { Image(systemName: "plus") }
                .help("Show the lyrics sooner (⌥⌘[)")
        }
        .buttonStyle(.borderless)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lyrics timing")
    }

    /// "In step", "0.3 s sooner", "1.2 s later".
    static func label(_ offset: Duration) -> String {
        guard offset != .zero else { return "In step" }
        let seconds = String(format: "%.1f s", abs(Double(offset.wholeMilliseconds)) / 1000)
        return offset > .zero ? "\(seconds) sooner" : "\(seconds) later"
    }
}

private struct LyricLine: View {
    let line: Lyrics.Line
    let position: LyricsPosition

    var body: some View {
        let current = position.line == line.id
        Group {
            if line.text.isEmpty {
                Text("♪").foregroundStyle(current ? .primary : .tertiary)
            } else if current, !line.words.isEmpty {
                // Sung words lit; the rest still to come.
                line.words.enumerated().reduce(Text(verbatim: "")) { text, item in
                    let sung = item.offset <= (position.word ?? -1)
                    return Text("\(text)\(Text(verbatim: item.element.text).foregroundStyle(sung ? .primary : .secondary))")
                }
            } else {
                Text(verbatim: line.text).foregroundStyle(current ? .primary : .secondary)
            }
        }
        .font(.title3.weight(current ? .bold : .regular))
        .opacity(current || position.line.map { line.id > $0 } ?? true ? 1 : 0.55)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.2), value: current)
        .help(line.time.map { "Play from \(TimeFormat.minutes(Int($0.components.seconds)))" } ?? "")
    }
}

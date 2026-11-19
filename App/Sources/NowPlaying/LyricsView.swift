import MiniAmpKit
import SwiftUI
import Translation

/// A song's lyrics, filling the library area: big, the song and the controls in the toolbar.
/// Synced lyrics follow playback, the line being sung kept in view (and, in word-timed
/// lyrics, its words lit as they're sung); clicking a line plays from there.
struct LyricsView<NowPlaying: View>: View {
    let app: AppState
    let url: URL
    /// Back to the library.
    let close: () -> Void
    /// The song playing, named in the toolbar.
    @ViewBuilder let nowPlaying: NowPlaying

    @State private var state: LoadState = .loading
    @State private var follower: LyricsFollower?
    /// The lyrics' language, and each line in Latin letters and translated (by line id).
    @State private var language: Locale.Language?
    @State private var needsRomanization = false
    @State private var romanized: [Int: String] = [:]
    @State private var translated: [Int: String] = [:]
    @State private var translation: TranslationSession.Configuration?
    @State private var translationError: String?
    /// The lines being made into a card, while the share sheet is open.
    @State private var sharing: LyricsShareTarget?

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
        /// The providers that are on, in order: a change in Settings may find something.
        var providers: [LyricsProviderID]
        /// Lyrics saved: read them again.
        var revision: Int
    }

    var body: some View {
        ScrollViewReader { proxy in
            full
            .onChange(of: follower?.position.line) { scroll(proxy, animated: true) }
            .onChange(of: state) { scroll(proxy, animated: false) }
        }
        .task(id: LoadKey(url: url, online: app.looksUpLyricsOnline, providers: app.lyricsProviders.enabled,
                           revision: app.lyricsRevision)) {
            if follower == nil { follower = LyricsFollower(player: app.player) }
            await app.loadLyricsOffset(for: url)
            follower?.offset = app.totalLyricsOffset(for: url)
            await load(app.looksUpLyricsOnline ? .automatic : .cachedOnly)
        }
        .onChange(of: app.totalLyricsOffset(for: url)) { follower?.offset = app.totalLyricsOffset(for: url) }
        .sheet(item: $sharing) { LyricsShareSheet(app: app, target: $0) }
        .onChange(of: app.showsLyricsTranslation) { updateTranslation() }
        .translationTask(translation) { session in
            guard case .found(let found) = state else { return }
            let lines = found.lyrics.lines.filter { !$0.text.isEmpty }.map { ($0.id, $0.text) }
            // The session and requests are only used here, inside the task SwiftUI made for the
            // session, as the Translation docs prescribe; the compiler can't see that they stay put.
            nonisolated(unsafe) let session = session
            nonisolated(unsafe) let requests = lines.map { TranslationSession.Request(sourceText: $0.1, clientIdentifier: String($0.0)) }
            guard !requests.isEmpty else { return }
            do {
                var out: [Int: String] = [:]
                for response in try await session.translations(from: requests) {
                    if let id = response.clientIdentifier.flatMap(Int.init) { out[id] = response.targetText }
                }
                translated = out
            } catch is CancellationError {
            } catch {
                translationError = "Couldn't translate: \(error.localizedDescription)"
            }
        }
    }

    /// Big lyrics, the line being sung a third of the way down, fading out at the edges.
    private var full: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    fullRows
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 48)
                .padding(.top, 32)
                .padding(.bottom, 280)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                       .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .fullViewToolbar(close: close) { nowPlaying } timing: {
            if case .found(let found) = state, !found.lyrics.isInstrumental, found.lyrics.isSynced {
                TimingControl(app: app, url: url)
            }
        } controls: { fullControls }
    }

    @ViewBuilder
    private var fullControls: some View {
        if case .found(let found) = state, !found.lyrics.isInstrumental {
            extrasMenu
            shareButton
        }
        if case .found = state { editButton }
    }

    @ViewBuilder
    private var fullRows: some View {
        switch state {
        case .found(let found) where !found.lyrics.isInstrumental:
            let synced = found.lyrics.isSynced
            ForEach(found.lyrics.lines) { line in
                LyricLine(line: line, position: synced ? follower?.position ?? LyricsPosition() : nil,
                          extras: extras(for: line), style: .full)
                    .id(line.id)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if synced, let time = line.time, let follower { app.player.seek(to: follower.playbackTime(for: time)) }
                    }
                    .contextMenu { shareMenuItem(from: line) }
            }
            sourceNotes(found).font(.callout).padding(.top, 24)
        default:
            rows.font(.title3)
        }
    }

    private var shareButton: some View {
        Button { share(from: follower?.position.line) } label: { Image(systemName: "square.and.arrow.up") }
            .buttonStyle(.borderless)
            .help("Share up to five lines as an image")
    }

    private func shareMenuItem(from line: Lyrics.Line?) -> some View {
        Button("Share Lyrics…") { share(from: line?.id) }
    }

    /// Opens the share sheet on the lyrics shown, with `line` chosen to start with.
    private func share(from line: Int?) {
        guard case .found(let found) = state, !found.lyrics.isInstrumental else { return }
        var shown: [Int: [String]] = [:]
        for line in found.lyrics.lines {
            let extras = extras(for: line)
            if !extras.isEmpty { shown[line.id] = extras }
        }
        sharing = LyricsShareTarget(url: url, lyrics: found.lyrics, extras: shown, startLine: line)
    }

    private var editButton: some View {
        Button { app.editLyrics() } label: { Image(systemName: "pencil") }
            .buttonStyle(.borderless)
            .help("Edit the lyrics, or time them to the song")
    }

    /// Where the lyrics came from, and how the translation went.
    private func sourceNotes(_ found: FoundLyrics) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(sourceLabel(found.source))
            if app.showsLyricsTranslation, !translated.isEmpty { Text("Translated on this Mac") }
            if let translationError, app.showsLyricsTranslation { Text(translationError) }
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var extrasToggles: some View {
        Toggle("Romanization", isOn: Binding(get: { app.showsLyricsRomanization }, set: { app.showsLyricsRomanization = $0 }))
            .disabled(!needsRomanization)
        Toggle(translationLabel, isOn: Binding(get: { app.showsLyricsTranslation }, set: { app.showsLyricsTranslation = $0 }))
            .disabled(!canTranslate)
    }

    /// Romanization and translation, shown under each line.
    private var extrasMenu: some View {
        Menu {
            extrasToggles
        } label: {
            Image(systemName: "character.bubble")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show the lyrics in Latin letters, or translated")
    }

    private var targetLanguage: Locale.Language { Locale.current.language }

    private var canTranslate: Bool {
        guard let code = language?.languageCode else { return false }
        return code != targetLanguage.languageCode
    }

    private var translationLabel: String {
        let name = targetLanguage.languageCode.flatMap { Locale.current.localizedString(forLanguageCode: $0.identifier) } ?? "Your Language"
        return "Translation into \(name)"
    }

    /// What to show under a line.
    private func extras(for line: Lyrics.Line) -> [String] {
        var out: [String] = []
        if app.showsLyricsRomanization, let latin = romanized[line.id] { out.append(latin) }
        if app.showsLyricsTranslation, let text = translated[line.id] { out.append(text) }
        return out
    }

    /// Works out the language and romanization for newly loaded lyrics, then translates if asked.
    private func prepareExtras(for lyrics: Lyrics) async {
        let (found, latin, needs) = await Task.detached(priority: .userInitiated) { () -> (Locale.Language?, [Int: String], Bool) in
            let language = LyricsLanguage.detect(lyrics)
            let needs = LyricsLanguage.needsRomanization(lyrics)
            return (language, needs ? LyricsLanguage.romanized(lyrics, language: language) : [:], needs)
        }.value
        guard !Task.isCancelled else { return }
        language = found
        romanized = latin
        needsRomanization = needs
        translated = [:]
        updateTranslation()
    }

    /// Starts (or stops) the translation task for the current lyrics. The system asks to
    /// download the languages the first time; after that it runs on this Mac.
    private func updateTranslation() {
        translationError = nil
        guard app.showsLyricsTranslation, canTranslate, translated.isEmpty, case .found = state else {
            if !app.showsLyricsTranslation { translation = nil }
            return
        }
        if translation?.source == language {
            translation?.invalidate()
        } else {
            translation = TranslationSession.Configuration(source: language, target: targetLanguage)
        }
    }


    @ViewBuilder
    private var rows: some View {
        switch state {
        case .loading:
            EmptyView()
        case .searching:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Searching \(app.lyricsProviderNames)…").foregroundStyle(.secondary)
            }
        case .found(let found) where found.lyrics.isInstrumental:
            Label("Instrumental: \(providerName(found.source) ?? "the file") says this song has no words.", systemImage: "pianokeys")
                .foregroundStyle(.secondary)
        case .found(let found):
            if found.lyrics.isSynced, let follower {
                ForEach(found.lyrics.lines) { line in
                    LyricLine(line: line, position: follower.position, extras: extras(for: line), style: .pane)
                        .contentShape(Rectangle())
                        .onTapGesture { if let time = line.time { app.player.seek(to: follower.playbackTime(for: time)) } }
                        .contextMenu { shareMenuItem(from: line) }
                        .listRowSeparator(.hidden)
                }
            } else if found.lyrics.hasVoices || found.lyrics.lines.contains(where: { !extras(for: $0).isEmpty }) {
                // A row per line, so each has its romanization or translation under it.
                ForEach(found.lyrics.lines) { line in
                    let side = VoiceSide(line)
                    VStack(alignment: side.alignment, spacing: 2) {
                        Text(verbatim: line.text.isEmpty ? " " : line.text)
                        ForEach(extras(for: line), id: \.self) { Text(verbatim: $0).font(.callout).foregroundStyle(.secondary) }
                    }
                    .multilineTextAlignment(side.textAlignment)
                    .frame(maxWidth: .infinity, alignment: side.frameAlignment)
                    .textSelection(.enabled)
                    .contextMenu { shareMenuItem(from: line) }
                    .listRowSeparator(.hidden)
                }
            } else {
                Text(found.lyrics.lines.map(\.text).joined(separator: "\n"))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contextMenu { shareMenuItem(from: nil) }
                    .listRowSeparator(.hidden)
            }
        case .none(let searched):
            VStack(alignment: .leading, spacing: 8) {
                Text(searched
                     ? "No lyrics in the file, beside it, or from \(app.lyricsProviderNames)."
                     : "No lyrics in the file or in a .lrc file beside it.")
                    .foregroundStyle(.secondary)
                HStack {
                    let providers = app.lyricsProviders.enabled
                    Button(searched ? "Search Online Again" : "Search Online") { Task { await load(.refresh) } }
                        .disabled(providers.isEmpty)
                        .help(providers.isEmpty
                              ? "Turn on a lyrics provider in Settings › Lyrics"
                              : "Sends this song's title, artist, album, and duration to \(providers.map(\.host).formatted())")
                    Button("Add Lyrics…") { app.editLyrics() }
                        .help("Type or paste the lyrics, and time them to the song")
                }
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
            let providers = app.lyricsProviders.enabled
            var result = try await app.lyricsFinder.find(for: wanted, online: online == .automatic ? .cachedOnly : online,
                                                         using: providers)
            // Show what's local or cached at once; only then wait on the network.
            if online == .automatic, case .notFound(searchedOnline: false) = result {
                state = .searching
                result = try await app.lyricsFinder.find(for: wanted, online: .automatic, using: providers)
            }
            guard !Task.isCancelled, wanted == url else { return }
            switch result {
            case .found(let found):
                state = .found(found)
                follower?.lyrics = found.lyrics
                await prepareExtras(for: found.lyrics)
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
        case .online(let provider, _): "From \(provider.name)"
        }
    }

    private func providerName(_ source: FoundLyrics.Source) -> String? {
        if case .online(let provider, _) = source { provider.name } else { nil }
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

enum LyricsStyle { case pane, full }

private struct LyricLine: View {
    let line: Lyrics.Line
    /// Where playback is; nil for unsynced lyrics, every line shown alike.
    let position: LyricsPosition?
    /// Romanization and translation, under the line.
    var extras: [String] = []
    var style: LyricsStyle

    var body: some View {
        let current = position == nil || position?.line == line.id
        let side = VoiceSide(line)
        VStack(alignment: side.alignment, spacing: style == .full ? 4 : 2) {
            text(current: current).font(lineFont(current: current))
            ForEach(extras, id: \.self) { extra in
                Text(verbatim: extra).font(style == .full ? .title3.weight(.semibold) : .callout)
                    .foregroundStyle(current ? .primary : .secondary)
            }
        }
        .opacity(current || position?.line.map { line.id > $0 } ?? true ? 1 : (style == .full ? 0.4 : 0.55))
        .multilineTextAlignment(side.textAlignment)
        .frame(maxWidth: .infinity, alignment: side.frameAlignment)
        .animation(.easeOut(duration: 0.2), value: current)
        .help(line.time.map { "Play from \(TimeFormat.minutes(Int($0.components.seconds)))" } ?? "")
    }

    private func lineFont(current: Bool) -> Font {
        switch style {
        case .pane: .title3.weight(current ? .bold : .regular)
        // As in Apple Music: every line bold, the one being sung lit.
        case .full: .system(size: 30, weight: .bold)
        }
    }

    @ViewBuilder
    private func text(current: Bool) -> some View {
        Group {
            if line.text.isEmpty {
                Text("♪").foregroundStyle(current ? .primary : .tertiary)
            } else if current, position != nil, !line.words.isEmpty {
                // Sung words lit; the rest still to come.
                line.words.enumerated().reduce(Text(verbatim: "")) { text, item in
                    let sung = item.offset <= (position?.word ?? -1)
                    return Text("\(text)\(Text(verbatim: item.element.text).foregroundStyle(sung ? .primary : .secondary))")
                }
            } else {
                Text(verbatim: line.text).foregroundStyle(current ? .primary : .secondary)
            }
        }
    }
}

/// Which side a duet line goes on, as in Apple Music: the first voice (and lines with none)
/// on the left, the others on the right.
struct VoiceSide {
    let trailing: Bool

    init(_ line: Lyrics.Line) { trailing = (line.voice ?? 1) > 1 }

    var alignment: HorizontalAlignment { trailing ? .trailing : .leading }
    var textAlignment: TextAlignment { trailing ? .trailing : .leading }
    var frameAlignment: Alignment { trailing ? .trailing : .leading }
}

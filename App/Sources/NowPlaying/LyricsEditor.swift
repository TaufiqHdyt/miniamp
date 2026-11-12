import MiniAmpKit
import SwiftUI

/// Edits a song's lyrics, as LRC text or by timing them to the song.
///
/// - Text: the lyrics as written (`[01:23.45]` times, `v1:`/`v2:` voices, word times), with
///   what the player will make of them beside it.
/// - Sync: the song plays and Return stamps the selected line with where it is, then moves
///   on; the arrows step through lines and nudge a time by a tenth of a second.
///
/// They're saved into the song's tags, or into the `.lrc` beside it when there is one.
struct LyricsEditor: View {
    let app: AppState
    let target: LyricsEditTarget
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var mode: Mode = .text
    @State private var document = LyricsDocument("")
    @State private var selected: Int?
    @State private var destination: Library.LyricsDestination = .tags
    @State private var confirmsRemoval = false
    @FocusState private var syncFocused: Bool

    enum Mode: Hashable { case text, sync }

    static let nudge = Duration.milliseconds(100)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Picker("Mode", selection: $mode) {
                Text("Text").tag(Mode.text)
                Text("Sync").tag(Mode.sync)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            switch mode {
            case .text: textMode
            case .sync: syncMode
            }
            footer
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 720, minHeight: 520, idealHeight: 600)
        .onAppear {
            text = target.text
            if let sidecar = target.sidecar, target.source != .embedded { destination = .sidecar(sidecar) }
        }
        .onChange(of: mode) {
            guard mode == .sync else { return }
            document = LyricsDocument(text)
            document.splitRepeatedLines()
            text = document.text
            selected = selected ?? document.lines.firstIndex(where: \.isLyric)
            syncFocused = true
        }
        .confirmationDialog("Remove this song's lyrics?", isPresented: $confirmsRemoval) {
            Button("Remove Lyrics", role: .destructive) { save(nil) }
        } message: {
            Text(removalMessage)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Lyrics: \(target.info.track.title)").font(.headline).lineLimit(1)
            Text([target.info.artistName, target.info.albumTitle].compactMap { $0 }.joined(separator: " — "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    // MARK: Text

    private var textMode: some View {
        let lyrics = Lyrics(lrc: text)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                ForEach(notes(lyrics), id: \.self) { note in
                    Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
            }
            preview(lyrics).frame(width: 230)
        }
    }

    /// The lyrics as they'll show: times, the second voice on the right.
    private func preview(_ lyrics: Lyrics) -> some View {
        List {
            Section(lyrics.isSynced ? "As Shown" : "As Shown (Not Timed)") {
                ForEach(lyrics.lines) { line in
                    let side = VoiceSide(line)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let time = line.time {
                            Text(LyricsDocument.format(time)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(verbatim: line.text.isEmpty ? "♪" : line.text)
                            .foregroundStyle(line.text.isEmpty ? .secondary : .primary)
                            .multilineTextAlignment(side.textAlignment)
                            .frame(maxWidth: .infinity, alignment: side.frameAlignment)
                    }
                    .font(.callout)
                }
            }
        }
        .listStyle(.inset)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// What to know about the text as written.
    private func notes(_ lyrics: Lyrics) -> [String] {
        var notes: [String] = []
        let document = LyricsDocument(text)
        if lyrics.isEmpty {
            notes.append("No lyrics. Saving removes the song's lyrics.")
        } else if !lyrics.isSynced {
            notes.append("Not timed: they'll show without following the song. Use Sync to time them.")
        }
        if document.untimedLyricCount > 0 {
            let count = document.untimedLyricCount
            notes.append("\(count) \(count == 1 ? "line has" : "lines have") no time, so \(count == 1 ? "it" : "they") won't be shown.")
        }
        let odd = document.lines.count { line in
            !line.isHeader && line.times.isEmpty && line.body.drop { $0 == " " }.first == "["
                && line.body.dropFirst().first.map { $0.isNumber } == true
        }
        if odd > 0 {
            notes.append("\(odd) \(odd == 1 ? "line starts" : "lines start") with a time that can't be read (it should look like [01:23.45]).")
        }
        if lyrics.hasVoices { notes.append("A duet: v2: lines show on the right.") }
        return notes
    }

    // MARK: Sync

    private var isPlayingThisSong: Bool { app.player.queue.current == target.url }

    private var syncMode: some View {
        VStack(alignment: .leading, spacing: 8) {
            syncBar
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(document.lines.indices.filter { document.lines[$0].isLyric }, id: \.self) { index in
                            syncRow(index).id(index)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(syncFocused ? Color.accentColor.opacity(0.6) : .secondary.opacity(0.3)))
                .focusable()
                .focusEffectDisabled()
                .focused($syncFocused)
                .onKeyPress(.return) { stamp(); return .handled }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.leftArrow) { shiftSelected(.zero - Self.nudge); return .handled }
                .onKeyPress(.rightArrow) { shiftSelected(Self.nudge); return .handled }
                .onKeyPress(.delete) { clearSelected(); return .handled }
                .onKeyPress(.space) {
                    app.perform { try await app.player.togglePlayPause() }
                    return .handled
                }
                .onChange(of: selected) {
                    if let selected { withAnimation { proxy.scrollTo(selected, anchor: UnitPoint(x: 0.5, y: 0.4)) } }
                }
            }
            Text("Return stamps the selected line and moves to the next. ↑ ↓ choose a line, ← → move its time by 0.1 s, ⌫ takes the time away, Space plays or pauses. Double-click a line to play from it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var syncBar: some View {
        HStack(spacing: 12) {
            if isPlayingThisSong {
                Button { app.perform { try await app.player.togglePlayPause() } } label: {
                    Image(systemName: app.player.state == .playing ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 16)
                }
                .help(app.player.state == .playing ? "Pause" : "Play")
                Button { app.player.seek(to: max(app.player.exactTime - .seconds(5), .zero)) } label: {
                    Image(systemName: "gobackward.5")
                }
                .help("Back 5 seconds")
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    Text(LyricsDocument.format(lyricsTime)).font(.body.monospacedDigit())
                }
                Spacer()
                Button("Stamp Line") { stamp() }
                    .disabled(selected == nil)
            } else {
                Label("Play this song to time its lyrics: it's no longer the one playing.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .buttonStyle(.borderless)
    }

    private func syncRow(_ index: Int) -> some View {
        let line = document.lines[index]
        let isSelected = selected == index
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(line.times.first.map(LyricsDocument.format) ?? "--:--.--")
                .font(.body.monospacedDigit())
                .foregroundStyle(line.times.isEmpty ? .tertiary : .secondary)
                .frame(width: 80, alignment: .leading)
            let words = line.displayText
            Text(verbatim: words.isEmpty ? "♪" : words)
                .foregroundStyle(words.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(syncFocused ? 0.25 : 0.12) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            selected = index
            if isPlayingThisSong, let time = line.times.first {
                app.player.seek(to: max(time - app.totalLyricsOffset(for: target.url), .zero))
            }
        }
        .onTapGesture {
            selected = index
            syncFocused = true
        }
    }

    /// Where the song is, in the lyrics' time: what a line stamped now gets. The song's timing
    /// correction and the delay for every song are counted, so the line shows when it was heard.
    private var lyricsTime: Duration {
        max(app.player.exactTime + app.totalLyricsOffset(for: target.url), .zero)
    }

    private func stamp() {
        guard isPlayingThisSong, let index = selected else { return }
        document.setTime(lyricsTime, ofLine: index)
        text = document.text
        move(1)
    }

    private func move(_ step: Int) {
        let lyrics = document.lines.indices.filter { document.lines[$0].isLyric }
        guard !lyrics.isEmpty else { return }
        guard let selected, let at = lyrics.firstIndex(of: selected) else {
            self.selected = lyrics.first
            return
        }
        self.selected = lyrics[min(max(at + step, 0), lyrics.count - 1)]
    }

    private func shiftSelected(_ delta: Duration) {
        guard let selected else { return }
        document.shift(line: selected, by: delta)
        text = document.text
    }

    private func clearSelected() {
        guard let selected else { return }
        document.setTime(nil, ofLine: selected)
        text = document.text
    }

    // MARK: Saving

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Remove Lyrics…", role: .destructive) { confirmsRemoval = true }
                .disabled(target.source.map(isFromLRCLIB) ?? true)
                .help("Take the lyrics out of the song")
            if let sidecar = target.sidecar {
                Picker("Save to", selection: $destination) {
                    Text(sidecar.lastPathComponent).tag(Library.LyricsDestination.sidecar(sidecar))
                    Text("The Song's Tags").tag(Library.LyricsDestination.tags)
                }
                .fixedSize()
                .overlay(alignment: .bottomLeading) {
                    if destination == .tags {
                        Text("\(sidecar.lastPathComponent) goes to the Trash")
                            .font(.caption2).foregroundStyle(.secondary).fixedSize()
                            .offset(y: 14)
                    }
                }
                .help(destination == .tags
                      ? "\(sidecar.lastPathComponent) goes to the Trash; otherwise it would be shown instead of the tags"
                      : "The .lrc file beside the song")
            } else {
                Text(saveNote).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save(text) }
                .keyboardShortcut("s")
                .disabled(text == target.text && !(target.source.map(isFromLRCLIB) ?? false))
        }
    }

    private var saveNote: String {
        if let source = target.source, isFromLRCLIB(source) { return "From LRCLIB; saving keeps them in the song's tags." }
        return "Saved in the song's tags."
    }

    private var removalMessage: String {
        switch target.source {
        case .sidecar(let file): "\(file.lastPathComponent) goes to the Trash."
        case .embedded: "They're taken out of the song's tags."
        case .lrclib, nil: ""
        }
    }

    private func isFromLRCLIB(_ source: FoundLyrics.Source) -> Bool {
        if case .lrclib = source { true } else { false }
    }

    private func save(_ text: String?) {
        let value = text.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var destination = destination
        // Removing takes them out of wherever they are.
        if value?.isEmpty ?? true {
            switch target.source {
            case .sidecar(let file): destination = .sidecar(file)
            case .embedded: destination = .tags
            default: break
            }
        }
        let saved = value?.isEmpty == false ? value : nil
        app.saveLyrics(saved, for: target, to: destination, trashingSidecar: saved != nil && destination == .tags)
        dismiss()
    }
}

import MiniAmpKit
import SwiftUI

/// Get Info: edits the tags of one or more tracks.
///
/// Each field starts with the value the tracks share, or empty with "Mixed" when they differ.
/// Only fields that were changed are written: a mixed field left alone keeps each track's own
/// value, and emptying a field removes that tag.
struct TagEditor: View {
    let app: AppState
    let tracks: [TrackInfo]
    @Environment(\.dismiss) private var dismiss
    @State private var values: [Field: String] = [:]
    @State private var initial: [Field: String] = [:]
    @State private var mixed: Set<Field> = []
    /// One song's lyrics, as in its tags; nil until read (and for several songs).
    @State private var lyrics: String?
    @State private var initialLyrics: String?
    @State private var sidecar: URL?

    enum Field: CaseIterable {
        case title, artist, album, albumArtist, genre, year, trackNumber, discNumber

        var label: String {
            switch self {
            case .title: "Title"
            case .artist: "Artist"
            case .album: "Album"
            case .albumArtist: "Album Artist"
            case .genre: "Genre"
            case .year: "Year"
            case .trackNumber: "Track"
            case .discNumber: "Disc"
            }
        }

        var isNumber: Bool { [.year, .trackNumber, .discNumber].contains(self) }

        func value(_ info: TrackInfo) -> String {
            let t = info.track
            switch self {
            case .title: return t.title
            case .artist: return info.artistName ?? ""
            case .album: return info.albumTitle ?? ""
            // Shown only when it's its own tag; the library otherwise falls back to the artist.
            case .albumArtist: return info.albumArtistName == info.artistName ? "" : info.albumArtistName ?? ""
            case .genre: return t.genre ?? ""
            case .year: return t.year.map(String.init) ?? ""
            case .trackNumber: return t.trackNumber.map(String.init) ?? ""
            case .discNumber: return t.discNumber.map(String.init) ?? ""
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Form {
                ForEach([Field.title, .artist, .album, .albumArtist, .genre], id: \.self) { field in
                    row(field)
                }
                HStack(spacing: 16) {
                    ForEach([Field.year, .trackNumber, .discNumber], id: \.self) { field in
                        row(field).frame(maxWidth: 140)
                    }
                }
            }
            .formStyle(.columns)
            if tracks.count == 1, lyrics != nil { lyricsField }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    app.saveTags(changes, of: tracks)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(changes.isEmpty || !numbersAreValid)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear(perform: load)
        .task {
            guard tracks.count == 1 else { return }
            let url = tracks[0].track.url
            let text = await LocalLyrics.text(of: .embedded, for: url) ?? ""
            sidecar = LocalLyrics.sidecar(for: url)
            initialLyrics = text
            lyrics = text
        }
    }

    /// The lyrics in the song's tags: plain, or LRC with times.
    private var lyricsField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Lyrics").font(.callout)
            TextEditor(text: Binding(get: { lyrics ?? "" }, set: { lyrics = $0 }))
                .font(.system(.callout, design: .monospaced))
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                .frame(height: 140)
            Text(sidecar.map { "\($0.lastPathComponent) beside the song is shown instead when it's timed. Edit Lyrics in the Lyrics pane can save there." }
                 ?? "Plain, or LRC with times ([01:23.45]). Edit Lyrics in the Lyrics pane times them to the song.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tracks.count == 1 ? tracks[0].track.title : CountFormat.songs(tracks.count))
                .font(.headline)
                .lineLimit(1)
            Text(tracks.count == 1 ? tracks[0].track.url.lastPathComponent : "Fields marked Mixed differ between them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func row(_ field: Field) -> some View {
        TextField(field.label, text: Binding(get: { values[field] ?? "" }, set: { values[field] = $0 }),
                  prompt: Text(mixed.contains(field) ? "Mixed" : ""))
            .help(field.isNumber ? "A number; empty removes it" : "")
    }

    private func load() {
        for field in Field.allCases {
            let all = Set(tracks.map(field.value))
            let shared = all.count == 1 ? all.first! : ""
            if all.count > 1 { mixed.insert(field) }
            values[field] = shared
            initial[field] = shared
        }
    }

    private func text(_ field: Field) -> String? {
        let value = (values[field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Unchanged, or a mixed field still empty: leave the tag alone.
        guard value != initial[field] else { return nil }
        return value
    }

    private func number(_ field: Field) -> Int? {
        guard let text = text(field) else { return nil }
        return text.isEmpty ? 0 : Int(text)
    }

    private var numbersAreValid: Bool {
        [Field.year, .trackNumber, .discNumber].allSatisfy { field in
            guard let text = text(field), !text.isEmpty else { return true }
            return Int(text).map { $0 > 0 } ?? false
        }
    }

    private var changes: TagChanges {
        TagChanges(title: text(.title), artist: text(.artist), album: text(.album), albumArtist: text(.albumArtist),
                   genre: text(.genre), year: number(.year), trackNumber: number(.trackNumber),
                   discNumber: number(.discNumber),
                   lyrics: lyrics == initialLyrics ? nil : lyrics?.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

import AppKit
import MiniAmpKit
import SwiftUI
import UniformTypeIdentifiers

/// Lyrics to make a card from: the song, its lines (with any romanization or translation
/// showing), and the line it was opened on.
struct LyricsShareTarget: Identifiable {
    let id = UUID()
    var url: URL
    var lyrics: Lyrics
    /// Shown under each line, by line id.
    var extras: [Int: [String]]
    var startLine: Int?
}

/// Picks up to five lines and shares them as an image: the lines over the cover's colour,
/// with the cover, title, and artist below. Shared, copied, or saved as a PNG.
struct LyricsShareSheet: View {
    static let maximumLines = 5

    let app: AppState
    let target: LyricsShareTarget
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<Int> = []
    @State private var entry: QueueEntry?
    @State private var cover: NSImage?
    /// The card as a PNG in the temporary folder, for the share menu; redone as lines change.
    @State private var file: URL?

    private var lines: [Lyrics.Line] { target.lyrics.lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                picker
                    .frame(width: 280)
                VStack(spacing: 8) {
                    card
                        .scaleEffect(0.6, anchor: .top)
                        .frame(width: LyricsCard.width * 0.6, height: LyricsCard.width * 0.6 * 1.25, alignment: .top)
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                    Text(selected.isEmpty ? "Choose lines on the left."
                                          : "\(selected.count) of \(Self.maximumLines) lines")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            Divider()
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Copy") { copy() }
                    .keyboardShortcut("c")
                    .help("Copy the card as an image")
                Button("Save…") { save() }
                    .help("Save the card as a PNG")
                if let file {
                    ShareLink(item: file, preview: SharePreview(fileTitle, image: Image(nsImage: NSImage(contentsOf: file) ?? NSImage()))) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button { } label: { Label("Share", systemImage: "square.and.arrow.up") }.disabled(true)
                }
            }
            .disabled(selected.isEmpty)
            .padding(16)
        }
        .frame(width: 280 + LyricsCard.width * 0.6 + 60)
        .task {
            if let start = target.startLine, lines.contains(where: { $0.id == start }) { selected = [start] }
            entry = await QueueEntry.load([target.url], from: app.library)[target.url] ?? QueueEntry(fileName: target.url)
            if let entry {
                if let key = entry.artworkKey, let artwork = app.library?.artwork {
                    cover = await ArtworkImages.shared.image(for: key, size: .large, in: artwork)
                } else if !entry.inLibrary {
                    cover = await ArtworkImages.shared.image(embeddedIn: target.url, size: .large)
                }
            }
            writeFile()
        }
        .onChange(of: selected) { writeFile() }
        .onChange(of: cover) { writeFile() }
    }

    private var picker: some View {
        List(lines) { line in
            let isOn = selected.contains(line.id)
            Toggle(isOn: Binding(get: { isOn }, set: { on in
                if on { selected.insert(line.id) } else { selected.remove(line.id) }
            })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: line.text)
                    ForEach(target.extras[line.id] ?? [], id: \.self) { Text(verbatim: $0).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!isOn && selected.count >= Self.maximumLines)
        }
        .listStyle(.bordered)
        .frame(height: LyricsCard.width * 0.6 * 1.25)
    }

    private var card: LyricsCard {
        let chosen = lines.filter { selected.contains($0.id) }
        return LyricsCard(lines: chosen.map { ($0.text, target.extras[$0.id] ?? []) },
                          title: entry?.title ?? target.url.deletingPathExtension().lastPathComponent,
                          artist: entry?.artist, cover: cover, tint: app.artworkTint)
    }

    private var fileTitle: String { "Lyrics – \(entry?.title ?? "Song")" }

    /// The card at twice its size: 1080 pixels wide.
    private func png() -> Data? {
        let renderer = ImageRenderer(content: card.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private func writeFile() {
        guard !selected.isEmpty, let data = png() else {
            file = nil
            return
        }
        let name = fileTitle.replacingOccurrences(of: "/", with: "-") + ".png"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            file = url
        } catch {
            file = nil
        }
    }

    private func copy() {
        guard let data = png() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
    }

    private func save() {
        guard let data = png() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = fileTitle.replacingOccurrences(of: "/", with: "-") + ".png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            dismiss()
        } catch {
            app.error = "Couldn't save the card: \(error.localizedDescription)"
        }
    }
}

/// The card itself: lyric lines in large type over the cover's colour (a dark wash for covers
/// with little colour, so the white text always reads), the song along the bottom.
struct LyricsCard: View {
    static let width: CGFloat = 540

    let lines: [(text: String, extras: [String])]
    let title: String
    let artist: String?
    let cover: NSImage?
    let tint: ArtworkTint?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: line.text)
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(.white)
                        ForEach(line.extras, id: \.self) { extra in
                            Text(verbatim: extra)
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(.white.opacity(0.72))
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 32)
            HStack(spacing: 12) {
                Group {
                    if let cover {
                        Image(nsImage: cover).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.white.opacity(0.15))
                            .overlay { Image(systemName: "music.note").foregroundStyle(.white.opacity(0.6)) }
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    if let artist, !artist.isEmpty {
                        Text(verbatim: artist).font(.system(size: 14)).foregroundStyle(.white.opacity(0.72))
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                Text("miniamp").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(40)
        .frame(width: Self.width, alignment: .leading)
        .frame(minHeight: Self.width * 0.75)
        .background { background }
    }

    /// The cover's colour, darkened enough under white text; a neutral dark without one.
    private var background: some View {
        let base = tint.map { Color(.sRGB, red: $0.red * 0.55, green: $0.green * 0.55, blue: $0.blue * 0.55) }
            ?? Color(.sRGB, red: 0.16, green: 0.16, blue: 0.18)
        let deep = tint.map { Color(.sRGB, red: $0.red * 0.25, green: $0.green * 0.25, blue: $0.blue * 0.25) }
            ?? Color(.sRGB, red: 0.07, green: 0.07, blue: 0.08)
        return LinearGradient(colors: [base, deep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

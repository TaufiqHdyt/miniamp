import Foundation

/// LRC text as the lyrics editor works on it, line by line: a line's time can be stamped or
/// nudged without touching anything else (headers, `v1:` voices, word times, other lines).
public struct LyricsDocument: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        /// The times at the line's start (`[01:23.45]`); empty for a plain line or a header.
        public var times: [Duration]
        /// Everything after the times: the voice prefix, the words, any `<mm:ss.xx>` word times.
        /// For a header, the whole line.
        public var body: String
        /// A header tag line (`[ar:…]`, `[offset:…]`): kept as it is, not a lyric.
        public var isHeader: Bool
        /// The times as written, until they're changed (so an untouched line keeps its form).
        fileprivate var writtenTimes: String?

        public init(times: [Duration] = [], body: String, isHeader: Bool = false) {
            self.times = times
            self.body = body
            self.isHeader = isHeader
        }

        /// A lyric (not a header), with words or a time: what sync mode steps through.
        public var isLyric: Bool { !isHeader && (!times.isEmpty || !body.trimmingCharacters(in: .whitespaces).isEmpty) }

        /// The words, without the voice prefix and word times: what to show for the line.
        public var displayText: String {
            Lyrics(lrc: "[00:00.00]" + body).lines.first?.text ?? ""
        }
    }

    public var lines: [Line]

    public init(_ text: String) {
        let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        lines = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(Self.line)
        // A trailing newline isn't a line.
        if lines.count > 1, let last = lines.last, last.times.isEmpty, !last.isHeader, last.body.isEmpty {
            lines.removeLast()
        }
    }

    /// The text, every line as it was unless its times were changed.
    public var text: String {
        lines.map { line in
            if line.isHeader { return line.body }
            let times = line.writtenTimes ?? line.times.map { "[\(Self.format($0))]" }.joined()
            return times + line.body
        }.joined(separator: "\n")
    }

    /// Whether any line has a time.
    public var isSynced: Bool { lines.contains { !$0.isHeader && !$0.times.isEmpty } }

    /// In synced lyrics, the lyric lines that still have no time: they'd be left out when shown.
    public var untimedLyricCount: Int {
        guard isSynced else { return 0 }
        return lines.count { $0.isLyric && $0.times.isEmpty }
    }

    /// Sets a line's time (nil takes it away). Its word times move with it, so the words stay
    /// where they were in the line.
    public mutating func setTime(_ time: Duration?, ofLine index: Int) {
        guard lines.indices.contains(index), !lines[index].isHeader else { return }
        let old = lines[index].times.first
        lines[index].times = time.map { [max($0, .zero)] } ?? []
        lines[index].writtenTimes = nil
        if let old, let time { lines[index].body = Self.shiftingWordTimes(lines[index].body, by: time - old) }
    }

    /// Moves a line's times (all of them, for a repeated line) and its word times.
    public mutating func shift(line index: Int, by delta: Duration) {
        guard lines.indices.contains(index), !lines[index].isHeader, !lines[index].times.isEmpty else { return }
        lines[index].times = lines[index].times.map { max($0 + delta, .zero) }
        lines[index].writtenTimes = nil
        lines[index].body = Self.shiftingWordTimes(lines[index].body, by: delta)
    }

    /// Writes a line sung at several times (`[00:12.00][01:30.00]a chorus`) once per time, all
    /// timed lines in time order, so each can be stamped on its own. Headers stay first; lines
    /// with no time go after (synced lyrics leave them out anyway). Does nothing when no line
    /// repeats.
    public mutating func splitRepeatedLines() {
        guard lines.contains(where: { $0.times.count > 1 }) else { return }
        let headers = lines.filter(\.isHeader)
        let timed = lines.filter { !$0.isHeader && !$0.times.isEmpty }
            .flatMap { line in line.times.map { Line(times: [$0], body: line.body) } }
            .enumerated().sorted { ($0.element.times[0], $0.offset) < ($1.element.times[0], $1.offset) }.map(\.element)
        let untimed = lines.filter(\.isLyric).filter(\.times.isEmpty)
        lines = headers + timed + untimed
    }

    /// "01:23.45": minutes and seconds to the hundredth, as LRC writes them.
    public static func format(_ time: Duration) -> String {
        let hundredths = (max(time.wholeMilliseconds, 0) + 5) / 10
        return String(format: "%02d:%02d.%02d", hundredths / 6000, hundredths / 100 % 60, hundredths % 100)
    }

    private static func line(_ raw: Substring) -> Line {
        var rest = raw.drop { $0 == " " || $0 == "\t" }
        var times: [Duration] = []
        var timesEnd = rest.startIndex
        while rest.first == "[", let close = rest.firstIndex(of: "]") {
            let tag = rest[rest.index(after: rest.startIndex)..<close]
            if let time = Lyrics.time(tag) {
                times.append(time)
            } else if times.isEmpty, Lyrics.headerTag(tag) != nil {
                return Line(body: String(raw), isHeader: true)
            } else {
                break
            }
            rest = rest[rest.index(after: close)...]
            timesEnd = rest.startIndex
        }
        guard !times.isEmpty else { return Line(body: String(raw)) }
        var line = Line(times: times, body: String(rest))
        line.writtenTimes = String(raw[raw.startIndex..<timesEnd])
        return line
    }

    private static func shiftingWordTimes(_ body: String, by delta: Duration) -> String {
        guard delta != .zero, body.contains("<") else { return body }
        var out = ""
        var rest = Substring(body)
        while let open = rest.firstIndex(of: "<") {
            out += rest[..<open]
            if let close = rest[open...].firstIndex(of: ">"), let time = Lyrics.time(rest[rest.index(after: open)..<close]) {
                out += "<\(format(time + delta))>"
                rest = rest[rest.index(after: close)...]
            } else {
                out += "<"
                rest = rest[rest.index(after: open)...]
            }
        }
        return out + rest
    }
}

extension Lyrics {
    /// The lyrics written as LRC (times, voices, and word times kept), for editing lyrics that
    /// came without a text of their own (from LRCLIB). Header tags aren't written.
    public var lrc: String {
        lines.map { line in
            let voice = line.voice.map { "v\($0): " } ?? ""
            let words = line.words.isEmpty ? line.text
                : line.words.map { "<\(LyricsDocument.format($0.time))>\($0.text)" }.joined()
            guard let time = line.time else { return voice + words }
            return "[\(LyricsDocument.format(time))]" + voice + words
        }.joined(separator: "\n")
    }
}

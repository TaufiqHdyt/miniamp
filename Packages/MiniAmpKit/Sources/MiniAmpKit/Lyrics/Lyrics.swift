import Foundation

/// A song's lyrics: timed lines (from LRC), or plain lines with no times.
public struct Lyrics: Sendable, Equatable {
    public struct Line: Sendable, Equatable, Identifiable {
        /// The line's index in `lines`.
        public var id: Int
        /// When the line starts; nil in plain lyrics.
        public var time: Duration?
        /// The whole line. Empty in a timed line marks a break (an instrumental passage).
        public var text: String
        /// Word timings from enhanced LRC, in order; empty when the line has none. Their
        /// texts, joined, make up `text`.
        public var words: [Word] = []
        /// Who sings it, in a duet: 1 for `v1:`, 2 for `v2:`, and so on (the prefix is taken
        /// out of `text`). Nil when the line has no prefix.
        public var voice: Int?
    }

    public struct Word: Sendable, Equatable {
        public var time: Duration
        public var text: String
    }

    /// Sorted by time when synced; in file order otherwise.
    public var lines: [Line]
    /// A track known to have no words (LRCLIB says so); `lines` is then empty.
    public var isInstrumental = false
    /// The LRC header tags: ar, ti, al, by, length, and so on (offset is already applied).
    public var metadata: [String: String] = [:]

    public init(lines: [Line], isInstrumental: Bool = false, metadata: [String: String] = [:]) {
        self.lines = lines
        self.isInstrumental = isInstrumental
        self.metadata = metadata
    }

    public var isSynced: Bool { lines.first?.time != nil }
    /// Some line is sung by a second (or later) voice: a duet.
    public var hasVoices: Bool { lines.contains { ($0.voice ?? 1) > 1 } }
    public var hasWordTiming: Bool { lines.contains { !$0.words.isEmpty } }
    /// No words to show (and not known to be instrumental): treat as no lyrics.
    public var isEmpty: Bool { !isInstrumental && lines.allSatisfy { $0.text.isEmpty } }

    public static let instrumental = Lyrics(lines: [], isInstrumental: true)
}

// MARK: - Following playback

/// Where playback is in synced lyrics.
public struct LyricsPosition: Sendable, Equatable {
    /// The line being sung: the last one that has started. Nil before the first.
    public var line: Int?
    /// In a word-timed line, the last word that has started (it and those before it are sung).
    public var word: Int?

    public init(line: Int? = nil, word: Int? = nil) {
        self.line = line
        self.word = word
    }
}

extension Lyrics {
    public func position(at time: Duration) -> LyricsPosition {
        guard isSynced, let line = Self.lastIndex(in: lines, startedBy: time, at: \.time) else { return LyricsPosition() }
        let words = lines[line].words
        return LyricsPosition(line: line, word: words.isEmpty ? nil : Self.lastIndex(in: words, startedBy: time, at: \.time))
    }

    /// The next time after `time` at which `position(at:)` changes, or nil if it never does again.
    public func nextChange(after time: Duration) -> Duration? {
        guard isSynced else { return nil }
        let current = position(at: time)
        var next: Duration?
        let nextLine = (current.line ?? -1) + 1
        if nextLine < lines.count { next = lines[nextLine].time }
        if let line = current.line {
            let words = lines[line].words
            let nextWord = (current.word ?? -1) + 1
            if nextWord < words.count, words[nextWord].time > time {
                next = min(next ?? words[nextWord].time, words[nextWord].time)
            }
        }
        return next
    }

    /// Binary search for the last element whose time is at or before `time`.
    private static func lastIndex<T>(in items: [T], startedBy time: Duration, at key: (T) -> Duration?) -> Int? {
        var low = 0, high = items.count
        while low < high {
            let mid = (low + high) / 2
            if let t = key(items[mid]), t <= time { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }
}

// MARK: - LRC

extension Lyrics {
    /// Parses LRC, including enhanced LRC's word times (`<mm:ss.xx>`), or plain text when it
    /// has no time tags.
    ///
    /// - Times can be `mm:ss`, `mm:ss.x`, `mm:ss.xx`, `mm:ss.xxx`, or `mm:ss:xx`; minutes can
    ///   go past 59. A line can have several (`[00:12.00][01:30.00]a chorus`).
    /// - `[offset:+n]` moves every time n ms earlier (a negative n, later).
    /// - In a synced file, lines with no time are dropped: there's nowhere to put them.
    /// - A line can start with who sings it, `v1:` or `v2:` (duets, as Apple Music's lyrics
    ///   mark them); see `Line.voice`.
    public init(lrc text: String) {
        var timed: [(time: Duration, order: Int, text: String, words: [Word], voice: Int?)] = []
        var plain: [(text: String, voice: Int?)] = []
        var metadata: [String: String] = [:]

        let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        for raw in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var rest = Substring(raw).drop { $0 == " " || $0 == "\t" }
            var times: [Duration] = []
            var isHeader = false
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let time = Self.time(tag) {
                    times.append(time)
                } else if times.isEmpty, let (key, value) = Self.headerTag(tag) {
                    metadata[key] = value
                    isHeader = true
                } else {
                    break // "[Chorus]" and the like: part of the text
                }
                rest = rest[rest.index(after: close)...]
            }
            if !times.isEmpty {
                let (found, body) = Self.voice(rest)
                var voice = found
                var (line, words) = Self.words(body)
                // The prefix after the first word's time: "<00:12.00>v2: words".
                if voice == nil, let first = words.first {
                    let (found, rest) = Self.voice(Substring(first.text))
                    if let found, !rest.isEmpty {
                        voice = found
                        words[0].text = String(rest)
                        line = words.map(\.text).joined()
                    }
                }
                for time in times {
                    timed.append((time, timed.count, line, words, voice))
                }
            } else if !isHeader {
                let (voice, body) = Self.voice(rest)
                plain.append((String(body).trimmingCharacters(in: .whitespaces), voice))
            }
        }

        if timed.isEmpty {
            // Plain text: keep stanza breaks, drop blank lines at either end.
            let start = plain.firstIndex { !$0.text.isEmpty } ?? plain.endIndex
            let end = plain.lastIndex { !$0.text.isEmpty }.map { $0 + 1 } ?? start
            self.init(lines: plain[start..<end].enumerated().map {
                Line(id: $0.offset, time: nil, text: $0.element.text, voice: $0.element.voice)
            }, metadata: metadata)
            return
        }

        let offset = metadata.removeValue(forKey: "offset").flatMap { Int($0.replacingOccurrences(of: "+", with: "")) } ?? 0
        let shift = Duration.milliseconds(offset)
        func shifted(_ t: Duration) -> Duration { max(t - shift, .zero) }

        timed.sort { ($0.time, $0.order) < ($1.time, $1.order) }
        let lines = timed.enumerated().map { index, item in
            Line(id: index, time: shifted(item.time), text: item.text,
                 words: item.words.map { Word(time: shifted($0.time < .zero ? item.time : $0.time), text: $0.text) },
                 voice: item.voice)
        }
        self.init(lines: lines, metadata: metadata)
    }

    /// "v2: words" → (2, "words"). Only a prefix at the start counts, lowercase v, then a
    /// number from 1 to 99 and a colon; anything else is left as words.
    static func voice(_ text: Substring) -> (Int?, Substring) {
        let trimmed = text.drop { $0 == " " || $0 == "\t" }
        guard trimmed.first == "v" else { return (nil, text) }
        let digits = trimmed.dropFirst().prefix { $0.isASCII && $0.isNumber }
        guard (1...2).contains(digits.count), let number = Int(digits), number > 0,
              trimmed.dropFirst(1 + digits.count).first == ":" else { return (nil, text) }
        return (number, trimmed.dropFirst(2 + digits.count).drop { $0 == " " || $0 == "\t" })
    }

    /// "[ar:Someone]" → ("ar", "Someone"). Keys are letters only, lowercased.
    static func headerTag(_ tag: Substring) -> (String, String)? {
        guard let colon = tag.firstIndex(of: ":") else { return nil }
        let key = tag[..<colon].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.allSatisfy(\.isLetter) else { return nil }
        return (key.lowercased(), tag[tag.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    /// "01:23.45", "1:23", "01:23.456", "01:23:45" (hundredths after a colon).
    static func time(_ tag: Substring) -> Duration? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let minutes = Int(parts[0].trimmingCharacters(in: .whitespaces)), minutes >= 0 else { return nil }
        let secondsPart = parts[1].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let seconds = Int(secondsPart[0]), seconds >= 0, secondsPart[0].count <= 2 else { return nil }
        var fraction: Substring = secondsPart.count == 2 ? secondsPart[1] : ""
        if parts.count == 3 {
            guard secondsPart.count == 1 else { return nil }
            fraction = parts[2]
        }
        guard fraction.allSatisfy(\.isASCII), fraction.allSatisfy(\.isNumber), fraction.count <= 3 else { return nil }
        let milliseconds = fraction.isEmpty ? 0 : Int(fraction.padding(toLength: 3, withPad: "0", startingAt: 0))!
        return .milliseconds(((minutes * 60) + seconds) * 1000 + milliseconds)
    }

    /// Splits a line at its `<mm:ss.xx>` word times. Returns the line's text (the times taken
    /// out, trimmed) and its words; no words when it has no times.
    private static func words(_ text: Substring) -> (String, [Word]) {
        guard text.contains("<") else { return (text.trimmingCharacters(in: .whitespaces), []) }
        var words: [Word] = []
        var lead = ""
        var rest = text
        while let open = rest.firstIndex(of: "<") {
            let before = String(rest[..<open])
            if words.isEmpty { lead += before } else { words[words.count - 1].text += before }
            guard let close = rest[open...].firstIndex(of: ">"),
                  let time = Self.time(rest[rest.index(after: open)..<close]) else {
                // Not a time: keep the "<" as text and go on after it.
                let after = rest.index(after: open)
                if words.isEmpty { lead += "<" } else { words[words.count - 1].text += "<" }
                rest = rest[after...]
                continue
            }
            words.append(Word(time: time, text: ""))
            rest = rest[rest.index(after: close)...]
        }
        if words.isEmpty { return ((lead + rest).trimmingCharacters(in: .whitespaces), []) }
        words[words.count - 1].text += rest
        // Text before the first time starts with the line: a word at the line's time, which
        // the caller fills in (it's marked with a negative time here).
        if !lead.trimmingCharacters(in: .whitespaces).isEmpty {
            words.insert(Word(time: .seconds(-1), text: lead), at: 0)
        }
        // Trim the line's ends, not the spaces between words; a trailing time (the line's end)
        // leaves an empty word, which is dropped.
        words[0].text = String(words[0].text.drop { $0 == " " || $0 == "\t" })
        while let last = words.last, last.text.trimmingCharacters(in: .whitespaces).isEmpty, words.count > 1 {
            words.removeLast()
        }
        words[words.count - 1].text = String(words[words.count - 1].text.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
        let line = words.map(\.text).joined()
        return line.isEmpty ? ("", []) : (line, words)
    }
}

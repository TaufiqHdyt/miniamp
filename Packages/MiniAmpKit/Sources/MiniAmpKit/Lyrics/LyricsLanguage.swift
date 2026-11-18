import Foundation
import NaturalLanguage

/// What language lyrics are in, and spelling them out in Latin letters.
public enum LyricsLanguage {
    /// The lyrics' dominant language, or nil when there's too little text to tell.
    public static func detect(_ lyrics: Lyrics) -> Locale.Language? {
        let text = lyrics.lines.map(\.text).joined(separator: "\n")
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }

    /// Whether the lyrics have letters outside the Latin script, so romanizing them changes something.
    public static func needsRomanization(_ lyrics: Lyrics) -> Bool {
        lyrics.lines.contains { line in line.text.unicodeScalars.contains(where: isNonLatinLetter) }
    }

    /// One line in Latin letters: Japanese and Chinese by the system's readings of each word
    /// (kanji read as Japanese in Japanese lyrics, as pinyin in Chinese), other scripts by
    /// transliteration. Latin text and punctuation are left as they are.
    public static func romanize(_ text: String, language: Locale.Language?) -> String {
        guard text.unicodeScalars.contains(where: isNonLatinLetter) else { return text }
        let code = language?.languageCode?.identifier
        let latin = code == "ja" || code == "zh"
            ? tokenized(text, locale: Locale(identifier: code!))
            : text.applyingTransform(.toLatin, reverse: false) ?? text
        return latinPunctuation(latin)
    }

    /// "、" → ", ", "「…」" → "“…”", full-width forms → ASCII.
    private static func latinPunctuation(_ text: String) -> String {
        var out = text
        for (cjk, latin) in [("、", ", "), ("。", ". "), ("「", "“"), ("」", "”"), ("『", "“"), ("』", "”"), ("・", " "), ("〜", "~")] {
            out = out.replacingOccurrences(of: cjk, with: latin)
        }
        out = out.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? out
        return out.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            .replacingOccurrences(of: " ,", with: ",").replacingOccurrences(of: " .", with: ".")
            .replacingOccurrences(of: "“ ", with: "“").replacingOccurrences(of: " ”", with: "”")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Romanized lines, by line id, for the lines that change.
    ///
    /// Kanji are read by the lyrics' script rather than their dominant language: lyrics mostly
    /// in English with Japanese lines are detected as English, and transliteration would read
    /// their kanji as Mandarin (君 as "jūn"). Any kana makes them Japanese.
    public static func romanized(_ lyrics: Lyrics, language: Locale.Language?) -> [Int: String] {
        let reading = readingLanguage(lyrics, detected: language)
        var out: [Int: String] = [:]
        for line in lyrics.lines where !line.text.isEmpty {
            let latin = romanize(line.text, language: reading)
            if latin != line.text { out[line.id] = latin }
        }
        return out
    }

    private static func tokenized(_ text: String, locale: Locale) -> String {
        let string = text as NSString
        let tokenizer = CFStringTokenizerCreate(nil, string, CFRange(location: 0, length: string.length),
                                                kCFStringTokenizerUnitWordBoundary, locale as CFLocale)
        var words: [String] = []
        var last = 0
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let token = string.substring(with: NSRange(location: range.location, length: range.length))
            // What lies between tokens (spaces, punctuation) is kept, trimmed.
            let between = string.substring(with: NSRange(location: last, length: range.location - last))
                .trimmingCharacters(in: .whitespaces)
            if !between.isEmpty { words.append(between) }
            last = range.location + range.length
            if let counted = countedReading(token, locale: locale) {
                words.append(counted)
            } else if let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String,
               token.unicodeScalars.contains(where: isNonLatinLetter) {
                words.append(latin)
            } else {
                words.append(token)
            }
        }
        let rest = string.substring(from: last).trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { words.append(rest) }
        // Punctuation sticks to the word before it.
        var out = ""
        for word in words {
            let isPunctuation = word.unicodeScalars.allSatisfy {
                !$0.properties.isAlphabetic && !$0.properties.isIdeographic && !CharacterSet.decimalDigits.contains($0)
            }
            if !out.isEmpty && !isPunctuation { out += " " }
            out += word
        }
        return out
    }

    /// A digit and a counter in Japanese ("2人"): the system reads the pair as Chinese ("2rén"),
    /// but a kanji numeral as Japanese ("二人" is "futari"), so the digit is read as one.
    private static func countedReading(_ token: String, locale: Locale) -> String? {
        guard locale.language.languageCode?.identifier == "ja", let first = token.unicodeScalars.first,
              let digit = Int(String(first)), digit > 0, token.unicodeScalars.count > 1,
              token.unicodeScalars.dropFirst().allSatisfy(\.properties.isIdeographic) else { return nil }
        let numerals = ["", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        return tokenized(numerals[digit] + String(token.unicodeScalars.dropFirst()), locale: locale)
    }

    /// Japanese when there's kana anywhere; otherwise the detected language, or Chinese for
    /// lyrics in Han characters with a language not worked out as Chinese or Japanese.
    static func readingLanguage(_ lyrics: Lyrics, detected: Locale.Language?) -> Locale.Language? {
        let scalars = lyrics.lines.lazy.flatMap(\.text.unicodeScalars)
        if scalars.contains(where: { (0x3040...0x30FF).contains($0.value) || (0x31F0...0x31FF).contains($0.value) }) {
            return Locale.Language(identifier: "ja")
        }
        let code = detected?.languageCode?.identifier
        if code != "ja", code != "zh", scalars.contains(where: \.properties.isIdeographic) {
            return Locale.Language(identifier: "zh")
        }
        return detected
    }

    private static func isNonLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.properties.isAlphabetic || scalar.properties.isIdeographic else { return false }
        return !(scalar.isASCII || (0x00C0...0x024F).contains(scalar.value) || (0x1E00...0x1EFF).contains(scalar.value))
    }
}

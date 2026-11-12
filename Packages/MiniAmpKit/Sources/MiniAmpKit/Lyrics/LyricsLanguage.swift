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
    public static func romanized(_ lyrics: Lyrics, language: Locale.Language?) -> [Int: String] {
        var out: [Int: String] = [:]
        for line in lyrics.lines where !line.text.isEmpty {
            let latin = romanize(line.text, language: language)
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
            if let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String,
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

    private static func isNonLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.properties.isAlphabetic || scalar.properties.isIdeographic else { return false }
        return !(scalar.isASCII || (0x00C0...0x024F).contains(scalar.value) || (0x1E00...0x1EFF).contains(scalar.value))
    }
}

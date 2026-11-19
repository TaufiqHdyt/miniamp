import Foundation

/// Repairs tag text written in a legacy East Asian encoding but read as Western: Shift-JIS
/// "エイベックス" that arrives as "ƒGƒCƒxƒbƒNƒX", GBK "你好" as "ÄãºÃ". Old taggers wrote such
/// bytes into fields marked Latin-1, and TagLib (rightly) reads them as Latin-1.
///
/// The text goes back to its bytes (through Windows-1252, Latin-1, or Cyrillic Windows-1251)
/// and is decoded as each
/// candidate encoding; the decoding that comes out as Japanese, Chinese, or Korean wins. Text
/// is only touched when it looks wrong: it has characters that are control codes in Latin-1
/// (bytes 0x80–0x9F, never in real Western text), or it is mostly accented letters. So
/// "Björk" and "Beyoncé" stay as they are.
public enum LegacyText {
    public static func repaired(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value >= 0x80 }) else { return text }
        for source in sources {
            guard let bytes = bytes(of: text, readAs: source.encoding), looksMisread(text, bytes, strict: source.strict) else { continue }
            // UTF-8 read as Latin-1 ("cafÃ©").
            if !source.strict, let utf8 = String(data: bytes, encoding: .utf8) { return utf8 }
            var best: (text: String, score: Int)?
            for encoding in candidates {
                guard let decoded = String(data: bytes, encoding: encoding), let score = score(decoded) else { continue }
                if score > (best?.score ?? 0) { best = (decoded, score) }
            }
            if let best { return best.text }
        }
        return text
    }

    /// What the bytes were wrongly read as: Western (Windows-1252, or Latin-1), or Cyrillic
    /// (Windows-1251: Shift-JIS "エイ" shows as "ѓGѓC"). Cyrillic is strict, so Russian text,
    /// which could decode as something, is left alone (see `looksMisread`).
    private static let sources: [(encoding: String.Encoding, strict: Bool)] = [
        (.windowsCP1252, false),
        (.windowsCP1251, true),
    ]

    /// Western text never has bytes 0x80–0x9F (control codes in Latin-1); text that's mostly
    /// accented letters is suspect too. Cyrillic text has a few (rare letters, quotes), so it
    /// has to be full of them, as Shift-JIS is: every kana starts with 0x81–0x83.
    private static func looksMisread(_ text: String, _ bytes: Data, strict: Bool) -> Bool {
        let high = bytes.filter { $0 >= 0x80 }.count
        let controls = bytes.filter { (0x80...0x9F).contains($0) }.count
        guard high > 0 else { return false }
        if strict { return Double(controls) / Double(high) >= 0.25 }
        let letters = text.unicodeScalars.filter { $0.properties.isAlphabetic }.count
        return controls > 0 || (letters > 0 && Double(high) / Double(letters) >= 0.5)
    }

    /// In order of preference when two score the same (kanji-only text reads as Shift-JIS,
    /// and as GBK; Chinese reads as GBK, and as Japanese EUC): the ones old taggers used most.
    private static let candidates: [String.Encoding] = [
        .shiftJIS,
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))),
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))),
        .japaneseEUC,
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue))),
    ]

    /// The bytes the text was read from, as `encoding` (Latin-1 for what it leaves out:
    /// taggers pass undefined bytes through as control codes). Nil when a character isn't
    /// one byte either way: the text was never a misread from this encoding.
    private static func bytes(of text: String, readAs encoding: String.Encoding) -> Data? {
        var bytes = Data()
        for scalar in text.unicodeScalars {
            if scalar.value < 0x80 {
                bytes.append(UInt8(scalar.value))
            } else if let byte = String(scalar).data(using: encoding), byte.count == 1 {
                bytes.append(byte[0])
            } else if scalar.value <= 0xFF {
                bytes.append(UInt8(scalar.value))
            } else {
                return nil
            }
        }
        return bytes
    }

    /// How surely a decoding is CJK text: kana count most (they settle Japanese against
    /// Chinese), then Han and Hangul. Nil when anything outside ASCII isn't CJK (letters,
    /// punctuation, full-width forms): a wrong guess leaves odd characters behind.
    private static func score(_ text: String) -> Int? {
        var score = 0
        for scalar in text.unicodeScalars where scalar.value >= 0x80 {
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF: score += 3       // kana
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: score += 1       // Han
            case 0xAC00...0xD7AF, 0x1100...0x11FF: score += 1       // Hangul
            case 0x3000...0x303F, 0xFF00...0xFFEF, 0x2010...0x206F, 0x00B7, 0x30FB: break // punctuation, full-width
            default: return nil
            }
        }
        return score > 0 ? score : nil
    }
}

import Foundation

/// Repairs tag text written in a legacy East Asian encoding but read as Western: Shift-JIS
/// "エイベックス" that arrives as "ƒGƒCƒxƒbƒNƒX", GBK "你好" as "ÄãºÃ". Old taggers wrote such
/// bytes into fields marked Latin-1, and TagLib (rightly) reads them as Latin-1.
///
/// The text goes back to its bytes (through Windows-1252, or Latin-1) and is decoded as each
/// candidate encoding; the decoding that comes out as Japanese, Chinese, or Korean wins. Text
/// is only touched when it looks wrong: it has characters that are control codes in Latin-1
/// (bytes 0x80–0x9F, never in real Western text), or it is mostly accented letters. So
/// "Björk" and "Beyoncé" stay as they are.
public enum LegacyText {
    public static func repaired(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value >= 0x80 }), let bytes = bytes(of: text) else { return text }
        let high = bytes.filter { $0 >= 0x80 }.count
        let letters = text.unicodeScalars.filter { $0.properties.isAlphabetic }.count
        let controls = bytes.contains { (0x80...0x9F).contains($0) }
        guard controls || (letters > 0 && Double(high) / Double(letters) >= 0.5) else { return text }

        // UTF-8 read as Latin-1 ("cafÃ©").
        if let utf8 = String(data: bytes, encoding: .utf8) { return utf8 }

        var best: (text: String, score: Int)?
        for encoding in candidates {
            guard let decoded = String(data: bytes, encoding: encoding), let score = score(decoded) else { continue }
            if score > (best?.score ?? 0) { best = (decoded, score) }
        }
        return best?.text ?? text
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

    /// The bytes the text was read from: each character's Windows-1252 byte, or its Latin-1
    /// one. Nil when a character is neither (the text was never a misread).
    private static func bytes(of text: String) -> Data? {
        var bytes = Data()
        for scalar in text.unicodeScalars {
            if scalar.value <= 0xFF {
                bytes.append(UInt8(scalar.value))
            } else if let byte = String(scalar).data(using: .windowsCP1252), byte.count == 1 {
                bytes.append(byte[0])
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

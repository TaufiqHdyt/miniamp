import Foundation
import Testing
@testable import MiniAmpKit

/// Issue #45: lyrics languages and romanization.
@Suite struct LyricsLanguageTests {
    @Test func detectsTheLanguage() {
        let japanese = Lyrics(lrc: "[00:01.00]君の名前を呼んでいる\n[00:05.00]夜空に星が光る")
        #expect(LyricsLanguage.detect(japanese)?.languageCode?.identifier == "ja")
        let english = Lyrics(lrc: "I feel your breath upon my neck\nA soft caress as cold as death")
        #expect(LyricsLanguage.detect(english)?.languageCode?.identifier == "en")
        #expect(!LyricsLanguage.needsRomanization(english))
        #expect(LyricsLanguage.needsRomanization(japanese))
        // Accented Latin doesn't need it.
        #expect(!LyricsLanguage.needsRomanization(Lyrics(lrc: "Ça va très bien, señor")))
    }

    @Test func romanizesJapaneseByReading() {
        let ja = Locale.Language(identifier: "ja")
        let latin = LyricsLanguage.romanize("夜空に星が光る", language: ja).lowercased()
        #expect(latin.contains("yozora"))
        #expect(latin.contains("hoshi"))
        // Latin words and punctuation stay.
        let mixed = LyricsLanguage.romanize("Hello、世界!", language: ja).lowercased()
        #expect(mixed == "hello, sekai!")
        #expect(LyricsLanguage.romanize("「夜空」。", language: ja).lowercased() == "“yozora”.")
    }

    @Test func romanizesOtherScripts() {
        #expect(LyricsLanguage.romanize("Привет, мир", language: Locale.Language(identifier: "ru")).lowercased() == "privet, mir")
        #expect(LyricsLanguage.romanize("안녕", language: Locale.Language(identifier: "ko")).lowercased().hasPrefix("an"))
        #expect(LyricsLanguage.romanize("Αγάπη", language: nil).lowercased().contains("ag"))
        #expect(LyricsLanguage.romanize("Plain English", language: nil) == "Plain English")
    }

    /// Mostly English, so detected as English; the kanji are still read as Japanese.
    @Test func readsKanjiAsJapaneseInMixedLyrics() throws {
        let lyrics = Lyrics(lrc: """
            [00:01.00]Hey, I'm the girl you threw away
            [00:02.00]まだ君のことが嫌い
            [00:03.00]So how you doing now are you ok?
            [00:04.00]Yea I'm alright, everything is fine
            [00:05.00]Sometime君を気にかけているよ
            """)
        let lines = LyricsLanguage.romanized(lyrics, language: Locale.Language(identifier: "en"))
        let second = try #require(lines[1])
        #expect(second.contains("kimi"))
        #expect(!second.contains("jūn"))
        #expect(lines[0] == nil)
        // A digit counting in Japanese is read as Japanese too.
        #expect(LyricsLanguage.romanize("日々2人歩いた", language: Locale.Language(identifier: "ja")).contains("futari"))
        // Han characters alone, with no language worked out: Chinese.
        let chinese = Lyrics(lrc: "[00:01.00]我爱你")
        #expect(LyricsLanguage.romanized(chinese, language: nil)[0]?.contains("wǒ") == true)
    }

    @Test func romanizesOnlyTheLinesThatChange() {
        let lyrics = Lyrics(lrc: "[00:01.00]Oh yeah\n[00:02.00]夜空\n[00:03.00]")
        let lines = LyricsLanguage.romanized(lyrics, language: Locale.Language(identifier: "ja"))
        #expect(Array(lines.keys) == [1])
    }
}

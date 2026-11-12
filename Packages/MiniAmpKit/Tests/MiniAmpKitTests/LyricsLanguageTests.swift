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

    @Test func romanizesOnlyTheLinesThatChange() {
        let lyrics = Lyrics(lrc: "[00:01.00]Oh yeah\n[00:02.00]夜空\n[00:03.00]")
        let lines = LyricsLanguage.romanized(lyrics, language: Locale.Language(identifier: "ja"))
        #expect(Array(lines.keys) == [1])
    }
}

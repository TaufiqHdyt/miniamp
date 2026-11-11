import AVFoundation
import Foundation
import GRDB
import Testing
@testable import MiniAmpKit

@Suite struct EnvironmentTests {
    @Test func tagLibLinks() {
        #expect(TagReader.tagLibVersion.hasPrefix("2."))
    }

    @Test func unreadableFileReturnsNil() {
        #expect(TagReader.read(URL(fileURLWithPath: "/nonexistent.flac")) == nil)
    }

    /// Writes a short 96 kHz / 24-bit ALAC file with AVAudioFile and reads it back with TagLib.
    @Test func readsHiResALAC() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniamp-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 96_000, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: 96_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitDepthHintKey: 24,
            ])
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
            buffer.frameLength = 96_000 // one second of silence
            try file.write(from: buffer)
        }

        let tags = try #require(TagReader.read(url))
        #expect(tags.sampleRate == 96_000)
        #expect(tags.bitsPerSample == 24)
        #expect(tags.channels == 2)
        #expect((Duration.milliseconds(950)...Duration.milliseconds(1050)).contains(tags.duration))
    }

    @Test func databaseOpensWithFTS5() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { try $0.execute(sql: "CREATE VIRTUAL TABLE t USING fts5(body)") }
        #expect(try !db.sqliteVersion.isEmpty)
    }
}

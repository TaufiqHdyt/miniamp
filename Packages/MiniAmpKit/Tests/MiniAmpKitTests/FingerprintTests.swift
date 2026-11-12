import AVFoundation
import Foundation
import GRDB
import Testing
@testable import MiniAmpKit

/// Issue #50: duplicates by Chromaprint fingerprints.
@Suite struct FingerprintTests {
    /// A melody: a note every quarter second, each a few harmonics, pitches drawn from `seed`.
    /// `lead` seconds of silence go first; `gain` scales it all.
    static func melody(seed: UInt64, seconds: Double = 30, lead: Double = 0, gain: Float = 0.3,
                       as spec: TestAudio.Spec) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniamp-melody-\(UUID().uuidString).\(spec.fileExtension)")
        var settings: [String: Any] = [AVFormatIDKey: spec.formatID, AVSampleRateKey: spec.sampleRate, AVNumberOfChannelsKey: 2]
        if spec.formatID == kAudioFormatMPEG4AAC { settings[AVEncoderBitRateKey] = 128_000 }
        let rate = spec.sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let frames = AVAudioFrameCount(rate * (seconds + lead))
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        var state = seed
        func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 33 }
        let noteFrames = Int(rate / 4)
        let leadFrames = Int(rate * lead)
        var pitches: [Double] = []
        for _ in 0...(Int(seconds * 4)) { pitches.append(220 * pow(2, Double(next() % 24) / 12)) }
        for i in 0..<Int(frames) {
            var sample: Float = 0
            if i >= leadFrames {
                let t = i - leadFrames
                let f = pitches[t / noteFrames]
                let phase = 2 * Double.pi * f * Double(t) / rate
                let envelope = Float(min(1, Double(t % noteFrames) / 200))
                sample = gain * envelope * Float(sin(phase) + 0.5 * sin(2 * phase) + 0.25 * sin(3 * phase)) / 1.75
            }
            buffer.floatChannelData![0][i] = sample
            buffer.floatChannelData![1][i] = sample
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        return url
    }

    @Test func sameRecordingMatchesAcrossEncodings() throws {
        let flac = try Self.melody(seed: 1, as: TestAudio.flac44k16)
        let aac = try Self.melody(seed: 1, gain: 0.15, as: TestAudio.aac48k)    // quieter, lossy, another rate
        let late = try Self.melody(seed: 1, lead: 2, as: TestAudio.flac44k16)  // starts 2 s in
        let other = try Self.melody(seed: 2, as: TestAudio.flac44k16)
        defer { for url in [flac, aac, late, other] { try? FileManager.default.removeItem(at: url) } }

        let a = try Fingerprints.compute(flac)
        #expect(a.count > 200) // ~8 values a second
        let same = Fingerprints.similarity(a, try Fingerprints.compute(aac))
        let shifted = Fingerprints.similarity(a, try Fingerprints.compute(late))
        let different = Fingerprints.similarity(a, try Fingerprints.compute(other))
        #expect(same >= Fingerprints.matchThreshold, "\(same)")
        #expect(shifted >= Fingerprints.matchThreshold, "\(shifted)")
        #expect(different < Fingerprints.matchThreshold, "\(different)")
        #expect(Fingerprints.similarity(a, a) == 1)
    }

    @Test func storesAndRoundTrips() throws {
        let values: [UInt32] = [0, 1, 0xDEADBEEF, .max]
        #expect(Fingerprints.decode(Fingerprints.encode(values)) == values)
        #expect(Fingerprints.similarity([1, 2], [1, 2]) == 0) // too short to say
    }

    @Test func shortFilesAreMarkedDone() async throws {
        let folder = try TestFolder()
        try folder.flac("Blip.flac") // 0.2 s
        let db = try AppDatabase.inMemory()
        let library = await Library(database: db, artwork: nil)
        try await library.addFolder(folder.url)
        await library.waitForScans()
        await library.fingerprintTracks()
        await library.waitForFingerprinting()
        #expect(try await db.writer.read { try Fingerprints.unfingerprinted($0).count } == 0)
        #expect(try await db.writer.read { try Fingerprints.all($0) }.isEmpty)
    }

    @Test func groupsTracksThatSoundAlike() async throws {
        let folder = try TestFolder()
        try FileManager.default.copyItem(at: try Self.melody(seed: 7, as: TestAudio.flac44k16), to: folder.url.appendingPathComponent("Original.flac"))
        try FileManager.default.copyItem(at: try Self.melody(seed: 7, as: TestAudio.aac48k), to: folder.url.appendingPathComponent("Mislabeled.m4a"))
        try FileManager.default.copyItem(at: try Self.melody(seed: 8, as: TestAudio.flac44k16), to: folder.url.appendingPathComponent("Other.flac"))
        let db = try AppDatabase.inMemory()
        let library = await Library(database: db, artwork: nil)
        try await library.addFolder(folder.url)
        await library.waitForScans()
        #expect(try await db.writer.read { try Fingerprints.unfingerprinted($0).count } == 3)

        await library.fingerprintTracks()
        await library.waitForFingerprinting()
        #expect(try await db.writer.read { try Fingerprints.unfingerprinted($0).count } == 0)

        let groups = try await db.writer.read { try Duplicates.findBySound($0) }
        #expect(groups.count == 1)
        let names = Set(groups.first?.entries.map { $0.info.track.url.lastPathComponent } ?? [])
        #expect(names == ["Original.flac", "Mislabeled.m4a"])
        // Lossless is the one to keep.
        #expect(groups.first?.entries.first?.info.track.url.lastPathComponent == "Original.flac")
        // Tag matching alone doesn't see them: neither has tags.
        #expect(try await db.writer.read { try Duplicates.find($0) }.isEmpty)

        // A changed file needs fingerprinting again.
        try await db.writer.write { try $0.execute(sql: "UPDATE track SET modifiedAt = modifiedAt + 1 WHERE path LIKE '%Other.flac'") }
        #expect(try await db.writer.read { try Fingerprints.unfingerprinted($0).count } == 1)
    }
}

import AVFoundation
import Foundation
import Testing
@testable import MiniAmpKit

/// Issue #2: each supported format opens and decodes through AVAudioFile at its native rate.
@Suite struct DecodingTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let spec: TestAudio.Spec
        let codec: String
        let bits: Int?
        var testDescription: String { "\(codec) \(spec.sampleRate)" }
    }

    static let cases: [Case] = [
        Case(spec: TestAudio.flac96k24, codec: "FLAC", bits: 24),
        Case(spec: TestAudio.flac44k16, codec: "FLAC", bits: 16),
        Case(spec: TestAudio.alac88k24, codec: "ALAC", bits: 24),
        Case(spec: TestAudio.aac48k, codec: "AAC", bits: nil),
    ]

    @Test(arguments: cases)
    func decodesAtNativeRate(_ c: Case) throws {
        let url = try TestAudio.write(c.spec)
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try AVAudioFile(forReading: url)
        #expect(AudioCodec.name(file.fileFormat.streamDescription.pointee.mFormatID) == c.codec)
        #expect(file.fileFormat.sampleRate == c.spec.sampleRate)
        #expect(file.processingFormat.sampleRate == c.spec.sampleRate)

        let decoded = try TestAudio.decodeAll(url)
        #expect(decoded.frameLength > 0)

        let tags = try #require(TagReader.read(url))
        #expect(tags.sampleRate == Int(c.spec.sampleRate))
        #expect(tags.bitsPerSample == c.bits, "TagLib bits \(String(describing: tags.bitsPerSample)), ASBD flags \(file.fileFormat.streamDescription.pointee.mFormatFlags)")
    }

    @Test func decodesMP3() throws {
        let url = TestAudio.mp3Fixture
        let file = try AVAudioFile(forReading: url)
        #expect(AudioCodec.name(file.fileFormat.streamDescription.pointee.mFormatID) == "MP3")
        #expect(file.processingFormat.sampleRate == 44_100)
        #expect(try TestAudio.decodeAll(url).frameLength > 0)
        #expect(TagReader.read(url)?.bitsPerSample == nil)
    }
}

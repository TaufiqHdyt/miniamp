import AVFoundation
import Foundation

/// Writes short encoded files with AVAudioFile, so tests don't depend on checked-in media.
enum TestAudio {
    struct Spec {
        var formatID: AudioFormatID
        var fileExtension: String
        var sampleRate: Double
        var bits: Int
        var channels: AVAudioChannelCount = 2
    }

    static let flac96k24 = Spec(formatID: kAudioFormatFLAC, fileExtension: "flac", sampleRate: 96_000, bits: 24)
    static let flac44k16 = Spec(formatID: kAudioFormatFLAC, fileExtension: "flac", sampleRate: 44_100, bits: 16)
    static let alac88k24 = Spec(formatID: kAudioFormatAppleLossless, fileExtension: "m4a", sampleRate: 88_200, bits: 24)
    static let aac48k = Spec(formatID: kAudioFormatMPEG4AAC, fileExtension: "m4a", sampleRate: 48_000, bits: 16)

    static var mp3Fixture: URL {
        Bundle.module.url(forResource: "tone-44k1", withExtension: "mp3", subdirectory: "Fixtures")!
    }

    /// Writes `seconds` of noise quantized to `spec.bits`, so lossless codecs round-trip exactly.
    static func write(_ spec: Spec, seconds: Double = 0.5) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniamp-test-\(UUID().uuidString).\(spec.fileExtension)")
        var settings: [String: Any] = [
            AVFormatIDKey: spec.formatID,
            AVSampleRateKey: spec.sampleRate,
            AVNumberOfChannelsKey: spec.channels,
        ]
        if spec.formatID == kAudioFormatMPEG4AAC {
            settings[AVEncoderBitRateKey] = 192_000
        } else {
            settings[AVEncoderBitDepthHintKey] = spec.bits
        }

        let format = AVAudioFormat(standardFormatWithSampleRate: spec.sampleRate, channels: spec.channels)!
        let frames = AVAudioFrameCount(spec.sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let scale = Float(1 << (spec.bits - 1))
        var rng = SystemRandomNumberGenerator()
        for ch in 0..<Int(spec.channels) {
            let data = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) {
                // Quiet noise (about -12 dBFS peak) on exact integer sample values.
                data[i] = Float(Int.random(in: -Int(scale / 4)..<Int(scale / 4), using: &rng)) / scale
            }
        }
        // Lossless encoders take their source bit depth from the client format and ignore
        // AVEncoderBitDepthHintKey for float input, so 16-bit files must be written from Int16.
        let source: AVAudioPCMBuffer
        let common: AVAudioCommonFormat
        if spec.bits == 16 {
            common = .pcmFormatInt16
            let int16 = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: spec.sampleRate,
                                      channels: spec.channels, interleaved: false)!
            source = AVAudioPCMBuffer(pcmFormat: int16, frameCapacity: frames)!
            source.frameLength = frames
            for ch in 0..<Int(spec.channels) {
                for i in 0..<Int(frames) {
                    source.int16ChannelData![ch][i] = Int16(buffer.floatChannelData![ch][i] * scale)
                }
            }
        } else {
            common = .pcmFormatFloat32
            source = buffer
        }

        // Scope the file so it's closed (and flushed) before anyone reads it.
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: common, interleaved: false)
            try file.write(from: source)
        }
        return url
    }

    static func decodeAll(_ url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                      frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return buffer
    }
}

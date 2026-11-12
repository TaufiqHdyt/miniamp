import AVFoundation

/// Something that reads decoded audio like an AVAudioFile does: Float32, deinterleaved.
protocol PCMReading: AnyObject {
    var processingFormat: AVAudioFormat { get }
    var length: AVAudioFramePosition { get }
    var framePosition: AVAudioFramePosition { get set }
    func read(into buffer: AVAudioPCMBuffer) throws
    func read(into buffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount) throws
}

extension AVAudioFile: PCMReading {}
extension DSDDecoder: PCMReading {}

enum PCMReader {
    /// Opens `url` for reading as PCM: through AVAudioFile, or a DSD file converted to PCM.
    static func open(_ url: URL) throws -> any PCMReading {
        if DSDFile.isDSD(url) { return try DSDDecoder(url: url, mode: .pcm) }
        return try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    }
}

import AVFoundation

/// A track opened for playback: a file AVAudioFile decodes, or a DSD file sent as DoP or
/// converted to PCM.
final class TrackFile {
    enum Kind: Sendable, Equatable {
        case pcm
        /// DSD packed into PCM frames for the DAC (see DSDDecoder). Must reach it bit for bit.
        case dop
        /// DSD filtered down to PCM.
        case dsdConverted
    }

    let url: URL
    let kind: Kind
    let processingFormat: AVAudioFormat
    let length: AVAudioFramePosition
    /// Set for PCM files: the node reads these itself.
    let audioFile: AVAudioFile?
    /// Set for DSD files: the scheduler streams these through a BufferPump.
    let dsd: DSDFile?

    init(_ file: AVAudioFile) {
        url = file.url
        kind = .pcm
        processingFormat = file.processingFormat
        length = file.length
        audioFile = file
        dsd = nil
    }

    init(dsd file: DSDFile, mode: DSDDecoder.Mode) throws {
        let decoder = try DSDDecoder(file: file, mode: mode)
        url = file.url
        kind = mode == .dop ? .dop : .dsdConverted
        processingFormat = decoder.processingFormat
        length = decoder.length
        audioFile = nil
        dsd = file
    }

    /// Opens `url`. For a DSD file, `dsdMode` picks DoP or PCM once the file's rate is known.
    static func open(_ url: URL, dsdMode: (DSDFile) -> DSDDecoder.Mode = { _ in .pcm }) throws -> TrackFile {
        if DSDFile.isDSD(url) {
            let file = try DSDFile(url: url)
            return try TrackFile(dsd: file, mode: dsdMode(file))
        }
        return TrackFile(try AVAudioFile(forReading: url))
    }

    var sampleRate: Double { processingFormat.sampleRate }

    var isDSD: Bool { dsd != nil }

    /// Whether this can play straight after `other` on the same node, with no gap: the same
    /// format, and the same kind (a DSD stream and a PCM file can't share a node session,
    /// and DoP mustn't follow anything that's scaled).
    func canFollow(_ other: TrackFile) -> Bool {
        kind == other.kind && processingFormat == other.processingFormat
    }

    /// A fresh decoder for this DSD track, for one thread's use.
    func makeDSDDecoder() throws -> DSDDecoder? {
        guard let dsd else { return nil }
        return try DSDDecoder(file: dsd, mode: kind == .dop ? .dop : .pcm)
    }
}

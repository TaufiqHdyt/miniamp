import AVFoundation
import Foundation
import Testing
@testable import MiniAmpKit

/// Issue #5: the engine graph built by Player hands the output exactly the decoded samples.
///
/// Uses offline manual rendering, so it runs without touching the audio hardware.
@MainActor
@Suite struct BitPerfectGraphTests {
    @Test(arguments: [TestAudio.flac96k24, TestAudio.flac44k16, TestAudio.alac88k24])
    func outputMatchesDecodedSamples(_ spec: TestAudio.Spec) throws {
        let url = try TestAudio.write(spec)
        defer { try? FileManager.default.removeItem(at: url) }

        let reference = try TestAudio.decodeAll(url)
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try Player.connectBitPerfect(node, in: engine, format: format)

        // Nothing between the player and the output: same format end to end, no mixer.
        #expect(engine.outputNode.inputFormat(forBus: 0) == format)
        #expect(engine.outputNode.outputFormat(forBus: 0).sampleRate == spec.sampleRate)
        // The output is fed by the player itself. (Don't touch mainMixerNode: reading it inserts a mixer.)
        #expect(engine.inputConnectionPoint(for: engine.outputNode, inputBus: 0)?.node === node)

        node.scheduleFile(file, at: nil)
        try engine.start()
        try node.playAudio()
        defer { engine.stop() }

        let rendered = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                        frameCapacity: reference.frameLength)!
        let chunk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        while rendered.frameLength < reference.frameLength {
            let want = min(4096, reference.frameLength - rendered.frameLength)
            let status = try engine.renderOffline(want, to: chunk)
            #expect(status == .success)
            append(chunk, to: rendered)
        }

        for ch in 0..<Int(format.channelCount) {
            let a = UnsafeBufferPointer(start: reference.floatChannelData![ch], count: Int(reference.frameLength))
            let b = UnsafeBufferPointer(start: rendered.floatChannelData![ch], count: Int(rendered.frameLength))
            let firstDiff = a.indices.first { a[$0].bitPattern != b[$0].bitPattern }
            #expect(firstDiff == nil, "channel \(ch) differs at frame \(firstDiff ?? -1)")
        }
    }

    private func append(_ chunk: AVAudioPCMBuffer, to dest: AVAudioPCMBuffer) {
        let start = Int(dest.frameLength)
        for ch in 0..<Int(chunk.format.channelCount) {
            (dest.floatChannelData![ch] + start)
                .update(from: chunk.floatChannelData![ch], count: Int(chunk.frameLength))
        }
        dest.frameLength += chunk.frameLength
    }
}

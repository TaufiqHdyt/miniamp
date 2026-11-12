import AVFoundation
import Foundation
import Testing
@testable import MiniAmpKit

/// Issues #7 and #8: tracks scheduled by TrackScheduler join with no gap, seeking starts at the
/// requested frame, and the reported position follows the render clock.
///
/// Rendered offline through the same graph as playback.
@MainActor
@Suite struct GaplessTests {
    @MainActor struct Rig {
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        let scheduler: TrackScheduler

        init(format: AVAudioFormat) throws {
            engine.attach(node)
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            try Player.connectBitPerfect(node, in: engine, format: format)
            scheduler = TrackScheduler(node: node)
        }

        func start() throws {
            try engine.start()
            try node.startPlayback()
        }

        /// Renders `frames` frames and returns channel 0 and 1.
        func render(_ frames: Int) throws -> [[Float]] {
            var out: [[Float]] = [[], []]
            let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
            while out[0].count < frames {
                let want = AVAudioFrameCount(min(4096, frames - out[0].count))
                let status = try engine.renderOffline(want, to: buffer)
                #expect(status == .success)
                for ch in 0..<2 {
                    out[ch] += UnsafeBufferPointer(start: buffer.floatChannelData![ch], count: Int(buffer.frameLength))
                }
            }
            return out
        }
    }

    static func samples(_ buffer: AVAudioPCMBuffer, channel: Int) -> [Float] {
        Array(UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength)))
    }

    static func firstDifference(_ a: [Float], _ b: [Float]) -> Int? {
        zip(a.indices, zip(a, b)).first { $0.1.0.bitPattern != $0.1.1.bitPattern }?.0
    }

    @Test(arguments: [TestAudio.flac96k24, TestAudio.alac88k24])
    func consecutiveTracksJoinSampleExactly(_ spec: TestAudio.Spec) throws {
        let a = try TestAudio.write(spec, seconds: 0.3)
        let b = try TestAudio.write(spec, seconds: 0.4)
        defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }
        let refA = try TestAudio.decodeAll(a), refB = try TestAudio.decodeAll(b)

        let fileA = try AVAudioFile(forReading: a)
        let fileB = try AVAudioFile(forReading: b)
        #expect(fileA.processingFormat == fileB.processingFormat)

        let rig = try Rig(format: fileA.processingFormat)
        rig.scheduler.append(fileA, token: 0)
        rig.scheduler.append(fileB, token: 1)
        try rig.start()
        defer { rig.engine.stop() }

        let total = Int(refA.frameLength + refB.frameLength)
        let out = try rig.render(total)
        for ch in 0..<2 {
            let expected = Self.samples(refA, channel: ch) + Self.samples(refB, channel: ch)
            let diff = Self.firstDifference(out[ch], expected)
            #expect(diff == nil, "channel \(ch) differs at frame \(diff ?? -1) (boundary at \(refA.frameLength))")
        }

        // The render clock is now at the end of B: the scheduler should report track B, at its end.
        let now = try #require(rig.scheduler.currentPosition())
        #expect(now.segment.token == 1)
        #expect(now.frame == fileB.length)
    }

    @Test func seekStartsAtRequestedFrame() throws {
        let url = try TestAudio.write(TestAudio.flac44k16, seconds: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let ref = try TestAudio.decodeAll(url)
        let file = try AVAudioFile(forReading: url)

        let rig = try Rig(format: file.processingFormat)
        let seekFrame: AVAudioFramePosition = 12_345
        rig.scheduler.append(file, from: seekFrame, token: 0)
        try rig.start()
        defer { rig.engine.stop() }

        let out = try rig.render(2_000)
        let expected = Array(Self.samples(ref, channel: 0)[Int(seekFrame)..<Int(seekFrame) + 2_000])
        #expect(Self.firstDifference(out[0], expected) == nil)
        #expect(rig.scheduler.currentPosition()?.frame == seekFrame + 2_000)
    }

    /// Player relies on this to start the next track (or stop) when a queue segment ends.
    @Test func segmentCompletionFiresInManualRenderingMode() async throws {
        let url = try TestAudio.write(TestAudio.flac44k16, seconds: 0.3)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)

        let rig = try Rig(format: file.processingFormat)
        var finished: [Int] = []
        rig.scheduler.onSegmentFinished = { finished.append($0.token) }
        rig.scheduler.append(file, token: 5)
        try rig.start()
        defer { rig.engine.stop() }

        _ = try rig.render(Int(file.length) + 1_024)
        for _ in 0..<50 where finished.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(finished == [5])
        #expect(rig.scheduler.segments.isEmpty)

        // A reset cancels without reporting a finish.
        rig.scheduler.append(file, token: 6)
        rig.scheduler.reset()
        try await Task.sleep(for: .milliseconds(100))
        #expect(finished == [5])
    }

    @Test func positionFollowsRenderClockAcrossBoundary() throws {
        let a = try TestAudio.write(TestAudio.flac44k16, seconds: 0.2) // 8820 frames
        let b = try TestAudio.write(TestAudio.flac44k16, seconds: 0.2)
        defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }
        let fileA = try AVAudioFile(forReading: a), fileB = try AVAudioFile(forReading: b)

        let rig = try Rig(format: fileA.processingFormat)
        rig.scheduler.append(fileA, token: 7)
        rig.scheduler.append(fileB, token: 8)
        try rig.start()
        defer { rig.engine.stop() }

        _ = try rig.render(4_000)
        var now = try #require(rig.scheduler.currentPosition())
        #expect(now.segment.token == 7)
        #expect(now.frame == 4_000)
        #expect(rig.scheduler.hasQueuedSegment)

        _ = try rig.render(Int(fileA.length)) // now 4000 frames into B
        now = try #require(rig.scheduler.currentPosition())
        #expect(now.segment.token == 8)
        #expect(now.frame == 4_000)
        #expect(!rig.scheduler.hasQueuedSegment)
    }
}

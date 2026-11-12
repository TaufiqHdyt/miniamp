import AVFoundation
import Foundation
import Testing
@testable import MiniAmpKit

/// Issue #42: crossfades skip silence, land on the beat, and play sample-exact on one node.
@Suite struct CrossfadeTests {
    static let rate = 44_100.0

    /// Drum-like hits every `60 / bpm` seconds from `firstBeat`, over a quiet tone, from `lead`
    /// to `seconds - trail`; silence outside that.
    static func song(bpm: Double, seconds: Double, lead: Double = 0, firstBeat: Double = 0, trail: Double = 0,
                     noise: Float = 0.2) -> [Float] {
        let n = Int(seconds * rate)
        var out = [Float](repeating: 0, count: n)
        let soundEnd = Int((seconds - trail) * rate)
        for i in Int(lead * rate)..<soundEnd { out[i] = 0.05 * sin(2 * .pi * 220 * Float(i) / Float(rate)) }
        var t = lead + firstBeat
        var rng = SystemRandomNumberGenerator()
        while t < seconds - trail {
            let s = Int(t * rate)
            for i in 0..<Int(0.08 * rate) where s + i < soundEnd {
                let env = exp(-Float(i) / Float(0.015 * rate))
                out[s + i] += 0.6 * env * sin(2 * .pi * 60 * Float(i) / Float(rate))
                    + noise * env * Float.random(in: -1...1, using: &rng)
            }
            t += 60 / bpm
        }
        return out
    }

    // MARK: Beats

    @Test(arguments: [120.0, 95.0, 140.0])
    func findsTheTempoAndThePhase(_ bpm: Double) throws {
        let firstBeat = 0.123
        let beats = try #require(BeatTracker.analyze(Self.song(bpm: bpm, seconds: 20, firstBeat: firstBeat), sampleRate: Self.rate))
        let period = 60 / bpm * Self.rate
        #expect(abs(beats.period - period) / period < 0.01, "period \(beats.period / Self.rate) s")
        // The phase is the first beat, to within an onset frame (10 ms).
        let error = (beats.phase - firstBeat * Self.rate).truncatingRemainder(dividingBy: period)
        #expect(min(abs(error), period - abs(error)) < 0.012 * Self.rate, "phase \(beats.phase / Self.rate) s")
        #expect(beats.confidence > 0.3)
    }

    @Test func noiseHasNoBeat() {
        var rng = SystemRandomNumberGenerator()
        let noise = (0..<Int(20 * Self.rate)).map { _ in Float.random(in: -0.3...0.3, using: &rng) }
        #expect(BeatTracker.analyze(noise, sampleRate: Self.rate) == nil)
        #expect(BeatTracker.analyze([Float](repeating: 0, count: Int(10 * Self.rate)), sampleRate: Self.rate) == nil)
    }

    // MARK: Planning

    @Test func skipsSilenceAtBothEnds() {
        // Steady tones: no beat, so the fade just spans the sound's last seconds.
        let tone = { (n: Int, from: Int, to: Int) -> [Float] in
            (0..<n).map { $0 >= from && $0 < to ? 0.3 * sin(2 * .pi * 440 * Float($0) / Float(Self.rate)) : 0 }
        }
        let r = Int(Self.rate)
        let tail = tone(20 * r, 0, 17 * r)          // three seconds of silence at the end
        let head = tone(15 * r, r * 3 / 2, 15 * r)  // a second and a half before it starts
        let plan = Crossfade.plan(tail: tail, head: head, sampleRate: Self.rate, duration: 5, matchesBeats: true)
        #expect(!plan.isBeatMatched)
        #expect(plan.length == AVAudioFramePosition(5 * r))
        #expect(abs(Int(plan.outStart) - 12 * r) <= r / 100, "fade starts at \(Double(plan.outStart) / Self.rate) s")
        // Ten milliseconds early, so a soft attack isn't clipped.
        #expect(abs(Int(plan.inStart) - (r * 3 / 2 - r / 100)) <= r / 100, "next starts at \(Double(plan.inStart) / Self.rate) s")
    }

    @Test func landsOnTheBeat() {
        let tail = Self.song(bpm: 120, seconds: 26, trail: 3)
        let head = Self.song(bpm: 124, seconds: 15, lead: 0.7, firstBeat: 0.1)
        let plan = Crossfade.plan(tail: tail, head: head, sampleRate: Self.rate, duration: 6, matchesBeats: true)
        #expect(plan.isBeatMatched)
        // Twelve beats of 0.5 s (three bars), starting on one, ending by the sound's end.
        #expect(abs(Double(plan.length) / Self.rate - 6) < 0.05, "fade of \(Double(plan.length) / Self.rate) s")
        let beat = (Double(plan.outStart) / Self.rate).truncatingRemainder(dividingBy: 0.5)
        #expect(min(beat, 0.5 - beat) < 0.015, "fade starts \(beat) s off the beat")
        #expect(Double(plan.outStart + plan.length) <= 23 * Self.rate + 1)
        // The next track enters on its first beat, 0.8 s in.
        #expect(abs(Double(plan.inStart) / Self.rate - 0.8) < 0.015, "next enters at \(Double(plan.inStart) / Self.rate) s")
    }

    @Test func withoutBeatMatchingTheFadeEndsWithTheSound() {
        let tail = Self.song(bpm: 120, seconds: 26, trail: 3)
        let head = Self.song(bpm: 124, seconds: 15, lead: 0.7)
        let plan = Crossfade.plan(tail: tail, head: head, sampleRate: Self.rate, duration: 6, matchesBeats: false)
        #expect(!plan.isBeatMatched)
        #expect(plan.length == AVAudioFramePosition(6 * Self.rate))
        #expect(abs(Double(plan.outStart + plan.length) / Self.rate - 23) < 0.02)
    }

    @Test func shortTracksGetAShorterFade() {
        let tail = Self.song(bpm: 120, seconds: 3, noise: 0)
        let head = Self.song(bpm: 120, seconds: 2, noise: 0)
        let plan = Crossfade.plan(tail: tail, head: head, sampleRate: Self.rate, duration: 10, matchesBeats: false)
        #expect(plan.length <= AVAudioFramePosition(2 * Self.rate))
        #expect(plan.outStart >= 0)
    }

    // MARK: Mixing and scheduling

    @Test func equalPowerFade() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1)!
        let n = 1_000
        func constant(_ value: Float) -> AVAudioPCMBuffer {
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            b.frameLength = AVAudioFrameCount(n)
            for i in 0..<n { b.floatChannelData![0][i] = value }
            return b
        }
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        out.frameLength = AVAudioFrameCount(n)
        Crossfade.mix(constant(1), from: 0, constant(0), from: 0, into: out, outgoingGain: 0.5)
        let down = Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: n))
        Crossfade.mix(constant(0), from: 0, constant(1), from: 0, into: out, outgoingGain: 0.5)
        let up = Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: n))
        #expect(abs(down[0] - 0.5) < 0.001 && down[n - 1] < 0.001)
        #expect(up[0] < 0.002 && abs(up[n - 1] - 1) < 0.001)
        // The two gains' powers sum to one all the way through (the outgoing one at its gain).
        for i in stride(from: 0, to: n, by: 97) {
            let a = down[i] / 0.5, b = up[i]
            #expect(abs(a * a + b * b - 1) < 0.001)
        }
    }

    /// The outgoing track up to the fade, the mixed fade, and the incoming track after it play
    /// back to back, and the scheduler reports the incoming track from the fade's first frame.
    @MainActor @Test func fadePlaysBetweenTheTracks() throws {
        let spec = TestAudio.flac44k16
        let a = try TestAudio.write(spec, seconds: 1.0), b = try TestAudio.write(spec, seconds: 1.0)
        defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }
        let refA = try TestAudio.decodeAll(a), refB = try TestAudio.decodeAll(b)
        let fileA = TrackFile(try AVAudioFile(forReading: a)), fileB = TrackFile(try AVAudioFile(forReading: b))

        let prepared = try #require(try Crossfade.prepare(outgoing: a, from: 20_000, incoming: b, duration: 0.3,
                                                          matchesBeats: false, outgoingGain: 1))
        let plan = prepared.plan
        #expect(plan.length == 13_230)
        #expect(plan.outStart + plan.length == fileA.length)

        let rig = try GaplessTests.Rig(format: fileA.processingFormat)
        rig.scheduler.append(fileA, to: 20_000, token: 0)
        rig.scheduler.append(fileA, from: 20_000, to: plan.outStart, token: 0, continues: true)
        rig.scheduler.append(prepared.buffer, standingFor: fileB, from: plan.inStart, token: 1)
        rig.scheduler.append(fileB, from: plan.inStart + plan.length, token: 1, continues: true)
        try rig.start()
        defer { rig.engine.stop() }

        let fadeStart = Int(plan.outStart), fade = Int(plan.length)
        let total = fadeStart + fade + Int(refB.frameLength) - Int(plan.inStart) - fade
        let out = try rig.render(fadeStart + fade / 2)
        let refAs = GaplessTests.samples(refA, channel: 0), mixed = GaplessTests.samples(prepared.buffer, channel: 0)
        #expect(GaplessTests.firstDifference(Array(out[0][..<fadeStart]), Array(refAs[..<fadeStart])) == nil)
        #expect(GaplessTests.firstDifference(Array(out[0][fadeStart...]), Array(mixed[..<(fade / 2)])) == nil)
        // Halfway through the fade it's the incoming track that's playing.
        let now = try #require(rig.scheduler.currentPosition())
        #expect(now.segment.token == 1)
        #expect(now.frame == plan.inStart + AVAudioFramePosition(fade / 2))

        let rest = try rig.render(total - fadeStart - fade / 2)
        let refBs = GaplessTests.samples(refB, channel: 0)
        let afterFade = Array(rest[0][(fade - fade / 2)...])
        #expect(GaplessTests.firstDifference(afterFade, Array(refBs[(Int(plan.inStart) + fade)...])) == nil)
        #expect(GaplessTests.firstDifference(Array(rest[0][..<(fade - fade / 2)]), Array(mixed[(fade / 2)...])) == nil)
    }
}

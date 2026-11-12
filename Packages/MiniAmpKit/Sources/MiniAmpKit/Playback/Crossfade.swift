import Accelerate
import AVFoundation

/// Crossfading from one track into the next, in DSP mode.
///
/// The overlap is mixed ahead of time into one buffer and scheduled between the end of the
/// outgoing track and the rest of the incoming one, all on the one player node: sample-exact,
/// and no mixer in the graph. Silence at the end of the outgoing track and the start of the
/// incoming one is skipped. With beat matching, the fade starts on a beat of the outgoing
/// track, lasts a whole number of its beats (whole bars when it's two or more), and the incoming track
/// enters on its first beat, so the two land together. Tempos aren't stretched: over a fade of
/// a few seconds, beats a few BPM apart stay close.
enum Crossfade {
    /// Where the fade goes, in each track's own frames.
    struct Plan: Sendable, Equatable {
        /// The outgoing track's frame where the fade begins; nothing after the fade is played.
        var outStart: AVAudioFramePosition
        /// The incoming track's frame that plays as the fade begins.
        var inStart: AVAudioFramePosition
        var length: AVAudioFramePosition
        var isBeatMatched: Bool
    }

    /// A plan and the mixed fade, ready to schedule. (The buffer isn't touched after it's made.)
    struct Prepared: @unchecked Sendable {
        let plan: Plan
        let buffer: AVAudioPCMBuffer
    }

    /// Below this, a level counts as silence (dBFS, RMS over 10 ms).
    static let silenceThreshold: Float = -50
    /// The incoming track's first beat is used only if it comes this soon after its sound starts.
    static let maximumLeadIn = 2.0

    // MARK: Planning

    /// Decides the fade from the outgoing track's last stretch (`tail`) and the incoming one's
    /// first (`head`), both mono. Frames in the plan are indexes into those arrays.
    static func plan(tail: [Float], head: [Float], sampleRate: Double, duration: Double, matchesBeats: Bool) -> Plan {
        let end = lastAudible(tail, sampleRate: sampleRate) ?? 0
        let start = firstAudible(head, sampleRate: sampleRate) ?? 0
        var length = min(Int(duration * sampleRate), end, head.count - start)
        var plan = Plan(outStart: AVAudioFramePosition(end - max(length, 0)), inStart: AVAudioFramePosition(start),
                        length: AVAudioFramePosition(max(length, 0)), isBeatMatched: false)
        guard matchesBeats, length > 0, let beats = BeatTracker.analyze(Array(tail[..<end]), sampleRate: sampleRate)
        else { return plan }

        // Whole beats that fit (a twentieth of a beat over is fine: the tempo is an estimate),
        // rounded down to whole bars of four when that loses at most a quarter of them.
        let room = min(end, head.count - start)
        var count = Int(Double(length) / beats.period + 0.05)
        if count >= 8 { count -= count % 4 }
        while count > 0, Double(count) * beats.period > Double(room) { count -= count > 4 ? 4 : 1 }
        guard count >= 1 else { return plan }
        length = Int((Double(count) * beats.period).rounded())
        guard let first = beats.positions(before: Double(end - length + 1)).last, first >= 0 else { return plan }
        plan.outStart = AVAudioFramePosition(first.rounded())
        plan.length = AVAudioFramePosition(length)
        plan.isBeatMatched = true

        // Bring the incoming track in on its first beat, if it has a clear one soon enough.
        let window = Array(head[start..<min(head.count, start + Int((maximumLeadIn + 8) * sampleRate))])
        if let incoming = BeatTracker.analyze(window, sampleRate: sampleRate),
           let beat = incoming.positions(before: Double(window.count)).first(where: { $0 >= 0 }),
           beat <= maximumLeadIn * sampleRate,
           start + Int(beat.rounded()) + length <= head.count {
            plan.inStart = AVAudioFramePosition(start + Int(beat.rounded()))
        }
        if Int(plan.inStart) + length > head.count { plan.inStart = AVAudioFramePosition(max(head.count - length, 0)) }
        return plan
    }

    /// The end of the last 10 ms above the silence threshold, or nil when it's all silence.
    static func lastAudible(_ samples: [Float], sampleRate: Double) -> Int? {
        let hop = max(Int(sampleRate / 100), 1)
        var block = (samples.count - 1) / hop
        while block >= 0 {
            if isAudible(samples, from: block * hop, count: min(hop, samples.count - block * hop)) {
                return min((block + 1) * hop, samples.count)
            }
            block -= 1
        }
        return nil
    }

    /// The start of the first 10 ms above the silence threshold, less 10 ms for a soft attack.
    static func firstAudible(_ samples: [Float], sampleRate: Double) -> Int? {
        let hop = max(Int(sampleRate / 100), 1)
        var block = 0
        while block * hop < samples.count {
            if isAudible(samples, from: block * hop, count: min(hop, samples.count - block * hop)) {
                return max((block - 1) * hop, 0)
            }
            block += 1
        }
        return nil
    }

    private static func isAudible(_ samples: [Float], from start: Int, count: Int) -> Bool {
        guard count > 0 else { return false }
        var squares: Float = 0
        samples.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + start, 1, &squares, vDSP_Length(count)) }
        let rms = (squares / Float(count)).squareRoot()
        return 20 * log10(max(rms, 1e-10)) > silenceThreshold
    }

    // MARK: Mixing

    /// Reads the two tracks, plans the fade, and mixes it. `tailStart` is where the outgoing
    /// track's analysed stretch begins; the plan's outgoing frame is absolute in that track.
    /// `outgoingGain` scales the outgoing track in the mix: the incoming track's ReplayGain
    /// takes over at the fade's start, so this makes up the difference.
    static func prepare(outgoing: URL, from tailStart: AVAudioFramePosition, incoming: URL,
                        duration: Double, matchesBeats: Bool, outgoingGain: Float) throws -> Prepared? {
        let a = try AVAudioFile(forReading: outgoing)
        let b = try AVAudioFile(forReading: incoming)
        let format = a.processingFormat
        guard format == b.processingFormat, format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              tailStart < a.length else { return nil }
        let rate = format.sampleRate
        a.framePosition = tailStart
        let tail = try read(a, frames: a.length - tailStart)
        let head = try read(b, frames: min(b.length, AVAudioFramePosition((duration + maximumLeadIn + 10) * rate)))

        let plan = Self.plan(tail: mono(tail), head: mono(head), sampleRate: rate, duration: duration,
                             matchesBeats: matchesBeats)
        guard plan.length > 0, let mixed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(plan.length))
        else { return nil }
        mixed.frameLength = AVAudioFrameCount(plan.length)
        mix(tail, from: Int(plan.outStart), head, from: Int(plan.inStart), into: mixed, outgoingGain: outgoingGain)
        var absolute = plan
        absolute.outStart += tailStart
        return Prepared(plan: absolute, buffer: mixed)
    }

    /// Equal-power: the outgoing track follows a quarter cosine down, the incoming a quarter
    /// sine up, so the loudness holds steady through the middle.
    static func mix(_ a: AVAudioPCMBuffer, from aStart: Int, _ b: AVAudioPCMBuffer, from bStart: Int,
                    into out: AVAudioPCMBuffer, outgoingGain: Float) {
        let n = Int(out.frameLength)
        guard n > 0 else { return }
        var down = [Float](repeating: 0, count: n), up = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = (Float(i) + 0.5) / Float(n) * .pi / 2
            down[i] = cos(t) * outgoingGain
            up[i] = sin(t)
        }
        for ch in 0..<Int(out.format.channelCount) {
            let x = a.floatChannelData![ch] + aStart, y = b.floatChannelData![ch] + bStart, z = out.floatChannelData![ch]
            vDSP_vmul(x, 1, down, 1, z, 1, vDSP_Length(n))
            vDSP_vma(y, 1, up, 1, z, 1, z, 1, vDSP_Length(n))
        }
    }

    private static func read(_ file: AVAudioFile, frames: AVAudioFramePosition) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(frames, 1)))
        else { throw CoreAudioError(status: kAudio_MemFullError, operation: "Crossfade buffer") }
        try file.read(into: buffer, frameCount: AVAudioFrameCount(max(frames, 0)))
        return buffer
    }

    /// The channels averaged, for analysis.
    static func mono(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let n = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
        var out = [Float](repeating: 0, count: n)
        guard n > 0, channels > 0, let data = buffer.floatChannelData else { return out }
        for ch in 0..<channels { vDSP_vadd(out, 1, data[ch], 1, &out, 1, vDSP_Length(n)) }
        var scale = 1 / Float(channels)
        vDSP_vsmul(out, 1, &scale, &out, 1, vDSP_Length(n))
        return out
    }
}

/// Finds the beat in a stretch of music: the tempo from how its onsets repeat, and the phase
/// from where they line up.
enum BeatTracker {
    struct Beats: Sendable, Equatable {
        /// Samples between beats.
        var period: Double
        /// The first beat's sample.
        var phase: Double
        /// How strongly the onsets repeat at this period, 0...1.
        var confidence: Double

        /// Every beat from the first up to (not including) `limit`, in samples.
        func positions(before limit: Double) -> [Double] {
            guard period > 0, limit > phase else { return [] }
            return stride(from: phase, to: limit, by: period).map { $0 }
        }
    }

    /// Below this the onsets don't repeat clearly enough to call it a beat.
    static let minimumConfidence = 0.2
    static let tempoRange = 60.0...200.0
    /// Onset frames per second.
    static let frameRate = 100.0

    /// The beat of `samples` (mono), or nil when there's no clear one (ambient, speech, silence).
    static func analyze(_ samples: [Float], sampleRate: Double) -> Beats? {
        let hop = max(Int(sampleRate / frameRate), 1)
        let frames = samples.count / hop
        guard frames > Int(frameRate * 3) else { return nil }

        // Onset strength: how far the level rises from one 10 ms frame to the next, in dB,
        // past half a dB (a steady tone's energy ripples by less from frame to frame), and at
        // most 20 dB (sound starting out of silence would otherwise outweigh every beat).
        var level = [Float](repeating: 0, count: frames)
        samples.withUnsafeBufferPointer { s in
            for k in 0..<frames {
                var e: Float = 0
                vDSP_svesq(s.baseAddress! + k * hop, 1, &e, vDSP_Length(hop))
                level[k] = 10 * log10(e / Float(hop) + 1e-10)
            }
        }
        var onset = [Double](repeating: 0, count: frames)
        for k in 1..<frames { onset[k] = Double(min(max(level[k] - level[k - 1] - 0.5, 0), 20)) }
        let mean = onset.reduce(0, +) / Double(frames)
        let centred = onset.map { $0 - mean }

        // Tempo: the lag at which the onsets repeat best, nudged towards 120 BPM so that a
        // beat isn't mistaken for half or double of itself.
        func autocorrelation(_ lag: Int) -> Double {
            var sum = 0.0
            for k in lag..<frames { sum += centred[k] * centred[k - lag] }
            return sum
        }
        let zero = autocorrelation(0)
        guard zero > 0 else { return nil }
        let minLag = Int((60 / tempoRange.upperBound * frameRate).rounded(.down))
        let maxLag = Int((60 / tempoRange.lowerBound * frameRate).rounded(.up))
        guard maxLag + 1 < frames else { return nil }
        let ac = (0...maxLag + 1).map { $0 >= minLag - 1 ? autocorrelation($0) : 0 }
        var best = minLag, bestScore = -Double.infinity
        for lag in minLag...maxLag {
            let octaves = log2(Double(lag) / (60 / 120 * frameRate))
            let score = ac[lag] / zero * exp(-0.5 * octaves * octaves)
            if score > bestScore { bestScore = score; best = lag }
        }
        let confidence = ac[best] / zero
        guard confidence >= minimumConfidence else { return nil }
        // Between frames: the peak of a parabola through the best lag and its neighbours.
        let (l, c, r) = (ac[best - 1], ac[best], ac[best + 1])
        let denominator = l - 2 * c + r
        let offset = denominator < 0 ? max(min(0.5 * (l - r) / denominator, 0.5), -0.5) : 0
        let period = Double(best) + offset

        // Phase: the offset whose beats land on the most onset.
        var bestPhase = 0, bestSum = -Double.infinity
        for phase in 0..<Int(period.rounded(.up)) {
            var sum = 0.0
            var t = Double(phase)
            while Int(t.rounded()) < frames {
                sum += onset[Int(t.rounded())]
                t += period
            }
            if sum > bestSum { bestSum = sum; bestPhase = phase }
        }
        // Refine both: the strongest onset near each predicted beat (the nearer, the stronger
        // it counts), and the straight line through them. A tempo a fraction of a percent off drifts tens of milliseconds over
        // a few dozen beats; this takes the drift out.
        var points: [(Double, Double)] = []
        var k = 0
        while true {
            let predicted = Double(bestPhase) + Double(k) * period
            let from = Int((predicted - period / 4).rounded(.up)), to = Int((predicted + period / 4).rounded(.down))
            guard from < frames else { break }
            let weight = { (f: Int) in onset[f] * (1 - abs(Double(f) - predicted) / (period / 4 + 1)) }
            let low = max(from, 1), high = min(to, frames - 1)
            if low <= high, let peak = (low...high).max(by: { weight($0) < weight($1) }), onset[peak] > 0 {
                points.append((Double(k), Double(peak)))
            }
            k += 1
        }
        var fitted = (phase: Double(bestPhase), period: period)
        if points.count >= 4 {
            let n = Double(points.count)
            let mx = points.map(\.0).reduce(0, +) / n, my = points.map(\.1).reduce(0, +) / n
            let sxx = points.map { ($0.0 - mx) * ($0.0 - mx) }.reduce(0, +)
            let sxy = points.map { ($0.0 - mx) * ($0.1 - my) }.reduce(0, +)
            if sxx > 0 {
                let slope = sxy / sxx
                // Only a refinement: a fit that wanders far from the tempo found is ignored.
                if abs(slope - period) < period * 0.05 { fitted = (my - slope * mx, slope) }
            }
        }
        // An onset frame stands for the middle of its 10 ms. The first beat is the earliest
        // one at or after the start.
        var phase = fitted.phase * Double(hop) + Double(hop / 2)
        let samplesPerBeat = fitted.period * Double(hop)
        while phase < 0 { phase += samplesPerBeat }
        while phase - samplesPerBeat >= 0 { phase -= samplesPerBeat }
        return Beats(period: samplesPerBeat, phase: phase, confidence: confidence)
    }
}

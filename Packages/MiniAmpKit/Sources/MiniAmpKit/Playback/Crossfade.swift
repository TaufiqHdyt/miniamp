import Accelerate
import AVFoundation
import os

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

    /// Decides the fade from the energy of the outgoing track's last stretch (`tail`) and the
    /// incoming one's first (`head`). Frames in the plan count from the start of each stretch.
    static func plan(tail: Envelope, head: Envelope, sampleRate: Double, duration: Double, matchesBeats: Bool) -> Plan {
        let end = lastAudible(tail) ?? 0
        let start = firstAudible(head) ?? 0
        var length = min(Int(duration * sampleRate), end, head.frames - start)
        var plan = Plan(outStart: AVAudioFramePosition(end - max(length, 0)), inStart: AVAudioFramePosition(start),
                        length: AVAudioFramePosition(max(length, 0)), isBeatMatched: false)
        guard matchesBeats, length > 0,
              let beats = BeatTracker.analyze(tail.prefix(hops: end / tail.hop), sampleRate: sampleRate)
        else { return plan }

        // Whole beats that fit (a twentieth of a beat over is fine: the tempo is an estimate),
        // rounded down to whole bars of four when that loses at most a quarter of them.
        let room = min(end, head.frames - start)
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
        let window = head.slice(fromHop: start / head.hop, hops: Int((maximumLeadIn + 8) * Envelope.hopsPerSecond))
        if let incoming = BeatTracker.analyze(window, sampleRate: sampleRate),
           let beat = incoming.positions(before: Double(window.frames)).first(where: { $0 >= 0 }),
           beat <= maximumLeadIn * sampleRate,
           start + Int(beat.rounded()) + length <= head.frames {
            plan.inStart = AVAudioFramePosition(start + Int(beat.rounded()))
        }
        if Int(plan.inStart) + length > head.frames { plan.inStart = AVAudioFramePosition(max(head.frames - length, 0)) }
        return plan
    }

    /// The same from samples (mono), for tests.
    static func plan(tail: [Float], head: [Float], sampleRate: Double, duration: Double, matchesBeats: Bool) -> Plan {
        plan(tail: Envelope(samples: tail, sampleRate: sampleRate), head: Envelope(samples: head, sampleRate: sampleRate),
             sampleRate: sampleRate, duration: duration, matchesBeats: matchesBeats)
    }

    /// The end of the last 10 ms above the silence threshold, or nil when it's all silence.
    static func lastAudible(_ envelope: Envelope) -> Int? {
        guard let hop = envelope.meanSquares.lastIndex(where: isAudible) else { return nil }
        return min((hop + 1) * envelope.hop, envelope.frames)
    }

    /// The start of the first 10 ms above the silence threshold, less 10 ms for a soft attack.
    static func firstAudible(_ envelope: Envelope) -> Int? {
        guard let hop = envelope.meanSquares.firstIndex(where: isAudible) else { return nil }
        return max(hop - 1, 0) * envelope.hop
    }

    static func firstAudible(_ samples: [Float], sampleRate: Double) -> Int? {
        firstAudible(Envelope(samples: samples, sampleRate: sampleRate))
    }

    private static func isAudible(_ meanSquare: Float) -> Bool {
        10 * log10(max(meanSquare, 1e-20)) > silenceThreshold
    }

    // MARK: Mixing

    /// Reads the two tracks, plans the fade, and mixes it. `tailStart` is where the outgoing
    /// track's analysed stretch begins; the plan's outgoing frame is absolute in that track.
    /// `outgoingGain` scales the outgoing track in the mix: the incoming track's ReplayGain
    /// takes over at the fade's start, so this makes up the difference.
    ///
    /// The analysis needs only each 10 ms's energy, so the tracks stream through one small
    /// buffer, and only the overlap itself is read in full, straight into the fade. (Decoding
    /// both stretches whole took about 90 MB at 96 kHz, which malloc then kept.)
    static func prepare(outgoing: URL, from tailStart: AVAudioFramePosition, incoming: URL,
                        duration: Double, matchesBeats: Bool, outgoingGain: Float) throws -> Prepared? {
        // An interval in Instruments' Points of Interest.
        let signposter = OSSignposter(subsystem: "dev.miniamp", category: .pointsOfInterest)
        let interval = signposter.beginInterval("Crossfade", "into \(incoming.lastPathComponent, privacy: .public)")
        defer { signposter.endInterval("Crossfade", interval) }
        let a = try AVAudioFile(forReading: outgoing)
        let b = try AVAudioFile(forReading: incoming)
        let format = a.processingFormat
        guard format == b.processingFormat, format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              tailStart < a.length else { return nil }
        let rate = format.sampleRate
        let hop = Envelope.hop(for: rate)
        guard let chunk = mappedBuffer(format: format, frames: AVAudioFrameCount(hop * 100)) else { return nil }

        let tail = try Envelope(reading: a, from: tailStart, frames: a.length - tailStart, hop: hop, through: chunk)
        let headFrames = min(b.length, AVAudioFramePosition((duration + maximumLeadIn + 10) * rate))
        let head = try Envelope(reading: b, from: 0, frames: headFrames, hop: hop, through: chunk)
        let plan = Self.plan(tail: tail, head: head, sampleRate: rate, duration: duration, matchesBeats: matchesBeats)
        guard plan.length > 0, let mixed = mappedBuffer(format: format, frames: AVAudioFrameCount(plan.length))
        else { return nil }

        // The outgoing track's part, read into the fade itself and turned down; then the
        // incoming track's, a chunk at a time, turned up and added in.
        // (In chunks: AVAudioFile decodes a big read through a temporary buffer as big.)
        let n = Int(plan.length)
        a.framePosition = tailStart + plan.outStart
        mixed.frameLength = AVAudioFrameCount(n)
        var copied = 0
        while copied < n {
            try a.read(into: chunk, frameCount: AVAudioFrameCount(min(Int(chunk.frameCapacity), n - copied)))
            let frames = Int(chunk.frameLength)
            guard frames > 0 else { return nil }
            for ch in 0..<Int(format.channelCount) {
                memcpy(mixed.floatChannelData![ch] + copied, chunk.floatChannelData![ch], frames * MemoryLayout<Float>.size)
            }
            copied += frames
        }
        for offset in stride(from: 0, to: n, by: Int(chunk.frameCapacity)) {
            applyRamp(down: true, gain: outgoingGain, to: mixed, at: offset,
                      frames: min(Int(chunk.frameCapacity), n - offset), of: n, adding: nil)
        }
        b.framePosition = plan.inStart
        var done = 0
        while done < n {
            try b.read(into: chunk, frameCount: AVAudioFrameCount(min(Int(chunk.frameCapacity), n - done)))
            let frames = Int(chunk.frameLength)
            guard frames > 0 else { break }
            applyRamp(down: false, gain: 1, to: mixed, at: done, frames: frames, of: n, adding: chunk)
            done += frames
        }
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
        for ch in 0..<Int(out.format.channelCount) {
            memcpy(out.floatChannelData![ch], a.floatChannelData![ch] + aStart, n * MemoryLayout<Float>.size)
        }
        applyRamp(down: true, gain: outgoingGain, to: out, at: 0, frames: n, of: n, adding: nil)
        guard let source = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: AVAudioFrameCount(n)) else { return }
        source.frameLength = AVAudioFrameCount(n)
        for ch in 0..<Int(b.format.channelCount) {
            memcpy(source.floatChannelData![ch], b.floatChannelData![ch] + bStart, n * MemoryLayout<Float>.size)
        }
        applyRamp(down: false, gain: 1, to: out, at: 0, frames: n, of: n, adding: source)
    }

    /// Frames `offset ..< offset + frames` of a fade `total` long: scales `out` in place by the
    /// falling gain (`down`), or adds `source` (from its first frame) times the rising one.
    private static func applyRamp(down: Bool, gain: Float, to out: AVAudioPCMBuffer, at offset: Int, frames: Int,
                                  of total: Int, adding source: AVAudioPCMBuffer?) {
        guard frames > 0 else { return }
        var ramp = [Float](repeating: 0, count: frames)
        var first = (Float(offset) + 0.5) / Float(total) * .pi / 2, step = Float.pi / 2 / Float(total)
        vDSP_vramp(&first, &step, &ramp, 1, vDSP_Length(frames))
        var count = Int32(frames)
        if down { vvcosf(&ramp, ramp, &count) } else { vvsinf(&ramp, ramp, &count) }
        if gain != 1 {
            var g = gain
            vDSP_vsmul(ramp, 1, &g, &ramp, 1, vDSP_Length(frames))
        }
        for ch in 0..<Int(out.format.channelCount) {
            let z = out.floatChannelData![ch] + offset
            if let source {
                vDSP_vma(source.floatChannelData![ch], 1, ramp, 1, z, 1, z, 1, vDSP_Length(frames))
            } else {
                vDSP_vmul(z, 1, ramp, 1, z, 1, vDSP_Length(frames))
            }
        }
    }

    /// A buffer in memory of its own, given back to the system as soon as it's freed. From
    /// malloc, a fade's megabytes would stay with the app after it had played.
    static func mappedBuffer(format: AVAudioFormat, frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        let channels = Int(format.channelCount)
        let bytesPerChannel = Int(frames) * MemoryLayout<Float>.size
        let size = max(bytesPerChannel * channels, 1)
        guard channels > 0, !format.isInterleaved, format.commonFormat == .pcmFormatFloat32,
              let memory = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
              memory != MAP_FAILED else { return nil }
        let list = AudioBufferList.allocate(maximumBuffers: channels)
        for ch in 0..<channels {
            list[ch] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytesPerChannel),
                                   mData: memory + ch * bytesPerChannel)
        }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer) { _ in
            munmap(memory, size)
            free(list.unsafeMutablePointer)
        }
        if buffer == nil {
            munmap(memory, size)
            free(list.unsafeMutablePointer)
        }
        buffer?.frameLength = 0
        return buffer
    }
}

/// How loud each 10 ms of a stretch of audio is: what the silence detection and the beat
/// tracker work from.
struct Envelope: Sendable {
    static let hopsPerSecond = 100.0

    /// Frames per 10 ms.
    let hop: Int
    /// The mean square of each hop's samples, over every channel.
    private(set) var meanSquares: [Float] = []
    /// Frames covered (the last hop may be short).
    private(set) var frames = 0
    private var partialSum: Float = 0
    private var partialCount = 0

    static func hop(for sampleRate: Double) -> Int { max(Int(sampleRate / hopsPerSecond), 1) }

    init(hop: Int) {
        self.hop = hop
    }

    init(samples: [Float], sampleRate: Double) {
        hop = Self.hop(for: sampleRate)
        samples.withUnsafeBufferPointer { if let base = $0.baseAddress { append([base], frames: samples.count) } }
        finish()
    }

    /// Reads `frames` frames of `file` from `start`, through `chunk`.
    init(reading file: AVAudioFile, from start: AVAudioFramePosition, frames total: AVAudioFramePosition, hop: Int,
         through chunk: AVAudioPCMBuffer) throws {
        self.hop = hop
        file.framePosition = start
        var left = total
        while left > 0 {
            try file.read(into: chunk, frameCount: AVAudioFrameCount(min(AVAudioFramePosition(chunk.frameCapacity), left)))
            let n = Int(chunk.frameLength)
            guard n > 0, let data = chunk.floatChannelData else { break }
            append((0..<Int(chunk.format.channelCount)).map { UnsafePointer(data[$0]) }, frames: n)
            left -= AVAudioFramePosition(n)
        }
        finish()
    }

    private mutating func append(_ channels: [UnsafePointer<Float>], frames n: Int) {
        var i = 0
        while i < n {
            let take = min(hop - partialCount, n - i)
            for channel in channels {
                var sum: Float = 0
                vDSP_svesq(channel + i, 1, &sum, vDSP_Length(take))
                partialSum += sum
            }
            partialCount += take
            i += take
            if partialCount == hop { flush(channels: channels.count) }
        }
        frames += n
        channelCount = channels.count
    }

    private var channelCount = 1

    private mutating func flush(channels: Int) {
        guard partialCount > 0 else { return }
        meanSquares.append(partialSum / Float(partialCount * max(channels, 1)))
        partialSum = 0
        partialCount = 0
    }

    private mutating func finish() { flush(channels: channelCount) }

    /// The first `hops` hops.
    func prefix(hops: Int) -> Envelope { slice(fromHop: 0, hops: hops) }

    /// `hops` hops from `first`.
    func slice(fromHop first: Int, hops: Int) -> Envelope {
        var out = Envelope(hop: hop)
        let from = min(max(first, 0), meanSquares.count), to = min(from + max(hops, 0), meanSquares.count)
        out.meanSquares = Array(meanSquares[from..<to])
        out.frames = min(to * hop, frames) - from * hop
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
        analyze(Envelope(samples: samples, sampleRate: sampleRate), sampleRate: sampleRate)
    }

    /// The beat of the audio `envelope` describes, or nil when there's no clear one.
    static func analyze(_ envelope: Envelope, sampleRate: Double) -> Beats? {
        let hop = envelope.hop
        let frames = envelope.meanSquares.count
        guard frames > Int(frameRate * 3) else { return nil }

        // Onset strength: how far the level rises from one 10 ms frame to the next, in dB,
        // past half a dB (a steady tone's energy ripples by less from frame to frame), and at
        // most 20 dB (sound starting out of silence would otherwise outweigh every beat).
        let level = envelope.meanSquares.map { 10 * log10($0 + 1e-10) }
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

import Accelerate
import AudioToolbox
import CoreAudio
import Synchronization

/// The audio going out, mixed to mono, for a visualizer: the output unit writes each render
/// into a ring on the I/O thread, and the display reads the stretch being heard right now.
///
/// Off unless something shows it (`users` > 0), when a render costs one atomic load more.
/// Never on while DoP goes out: those samples are DSD bits, not sound.
public final class SampleTap: @unchecked Sendable {
    /// About a third of a second at 48 kHz: room for the analysis window, the device's
    /// latency and a late reader.
    static let capacity = 32_768

    private let ring: UnsafeMutablePointer<Float>
    /// Samples written since the start; the newest is at `(written - 1) % capacity`.
    private let written = Atomic<Int>(0)
    /// When the first sample of the latest render is played, in host time, and that render's
    /// first sample's number.
    private let renderHostTime = Atomic<UInt64>(0)
    private let renderStart = Atomic<Int>(0)
    private let rateBits = Atomic<UInt64>(Double(44_100).bitPattern)
    /// Seconds from a render's timestamp to the sound leaving the device.
    private let latencyBits = Atomic<UInt64>(Double(0).bitPattern)
    private let users = Atomic<Int>(0)
    private let suppressed = Atomic<Bool>(false)

    init() {
        ring = .allocate(capacity: Self.capacity)
        ring.initialize(repeating: 0, count: Self.capacity)
    }

    deinit { ring.deallocate() }

    // MARK: Control

    var isCapturing: Bool { users.load(ordering: .relaxed) > 0 && !suppressed.load(ordering: .relaxed) }

    /// Counts the visualizers showing; capture runs while there's at least one.
    public func setActive(_ active: Bool) {
        if active {
            users.add(1, ordering: .relaxed)
        } else {
            users.subtract(1, ordering: .relaxed)
        }
    }

    /// Whether what goes out isn't sound (DoP).
    func setSuppressed(_ value: Bool) {
        suppressed.store(value, ordering: .relaxed)
        if value { clear() }
    }

    /// Whether the output is DoP, when a visualizer has nothing to show.
    public var isSuppressed: Bool { suppressed.load(ordering: .relaxed) }

    /// The output's format and latency, set when it's configured.
    func configure(sampleRate: Double, latency: Double) {
        rateBits.store(sampleRate.bitPattern, ordering: .relaxed)
        latencyBits.store(latency.bitPattern, ordering: .relaxed)
        clear()
    }

    public var sampleRate: Double { Double(bitPattern: rateBits.load(ordering: .relaxed)) }

    /// Forgets what's been captured: a reader then sees silence until new audio arrives.
    func clear() {
        renderHostTime.store(0, ordering: .relaxed)
        written.store(0, ordering: .releasing)
    }

    // MARK: Writing (I/O thread)

    /// Mixes `frames` of deinterleaved Float32 down to mono into the ring.
    func write(_ data: UnsafeMutablePointer<AudioBufferList>, frames: Int, hostTime: UInt64) {
        let buffers = UnsafeMutableAudioBufferListPointer(data)
        guard frames > 0, buffers.count > 0, frames <= Self.capacity else { return }
        let start = written.load(ordering: .relaxed)
        var done = 0
        while done < frames {
            let at = (start + done) % Self.capacity
            let run = min(frames - done, Self.capacity - at)
            let out = ring + at
            var first = true
            for buffer in buffers {
                guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                if first {
                    out.update(from: samples + done, count: run)
                    first = false
                } else {
                    vDSP_vadd(out, 1, samples + done, 1, out, 1, vDSP_Length(run))
                }
            }
            if first { out.update(repeating: 0, count: run) }
            if buffers.count > 1 {
                var scale = 1 / Float(buffers.count)
                vDSP_vsmul(out, 1, &scale, out, 1, vDSP_Length(run))
            }
            done += run
        }
        renderStart.store(start, ordering: .relaxed)
        renderHostTime.store(hostTime, ordering: .relaxed)
        written.store(start + frames, ordering: .releasing)
    }

    // MARK: Reading (any one thread)

    /// Copies the `count` samples ending at the one being heard now into `out`. Samples not
    /// captured (nothing playing yet, or capture just started) are silence. Returns whether
    /// any audio was there.
    @discardableResult
    public func latest(_ count: Int, into out: UnsafeMutablePointer<Float>) -> Bool {
        precondition(count <= Self.capacity / 2)
        for _ in 0..<2 {
            let total = written.load(ordering: .acquiring)
            guard total > 0 else { break }
            let heard = heardSample(total: total)
            // Long past the last render: the output has stopped (paused), so nothing sounds.
            guard heard - total < Int(sampleRate * 0.1) else { break }
            let end = min(heard, total)
            let begin = end - count
            let oldest = max(total - Self.capacity, 0)
            // What's in the ring and wanted, copied; the rest silence.
            let from = max(begin, oldest)
            let silence = min(max(from - begin, 0), count)
            if silence > 0 { out.update(repeating: 0, count: silence) }
            var i = from
            while i < end {
                let at = i % Self.capacity
                let run = min(end - i, Self.capacity - at)
                (out + (i - begin)).update(from: ring + at, count: run)
                i += run
            }
            // Torn if the writer went round onto what was copied meanwhile.
            if written.load(ordering: .acquiring) - Self.capacity <= from { return end > from }
        }
        out.update(repeating: 0, count: count)
        return false
    }

    /// The number of the sample leaving the device now, by the latest render's timestamp.
    private func heardSample(total: Int) -> Int {
        let hostTime = renderHostTime.load(ordering: .relaxed)
        guard hostTime > 0 else { return total }
        let now = mach_absolute_time()
        let latency = Double(bitPattern: latencyBits.load(ordering: .relaxed))
        let elapsed = (Double(Int64(bitPattern: now &- hostTime)) * Self.ticksToSeconds) - latency
        return renderStart.load(ordering: .relaxed) + Int((elapsed * sampleRate).rounded(.down))
    }

    private static let ticksToSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()
}

import AVFoundation

/// Feeds a player node audio it can't read from a file itself (DSD), as buffers scheduled a
/// second or so ahead of what's rendering. It works on its own queue and refills from the
/// node's completion callbacks, so a busy main thread doesn't starve playback.
///
/// Jobs play in the order they're appended, back to back. Nothing else may be scheduled on the
/// node while a job is streaming, or it would play out of order.
final class BufferPump: @unchecked Sendable {
    struct Job {
        let decoder: DSDDecoder
        let start: AVAudioFramePosition
        let end: AVAudioFramePosition
        /// Called on the pump's queue once the job's last frame has been rendered.
        let onFinished: @Sendable () -> Void
    }

    static let chunkFrames: AVAudioFrameCount = 16_384
    static let aheadSeconds = 1.0

    private let node: AVAudioPlayerNode
    private let queue = DispatchQueue(label: "dev.miniamp.pump", qos: .userInteractive)

    // Only touched on `queue`.
    private var jobs: [Job] = []
    private var next: AVAudioFramePosition = 0
    private var generation = 0
    /// Frames scheduled and not yet rendered.
    private var ahead: AVAudioFramePosition = 0
    /// Frames scheduled since the reset, which keeps DoP markers alternating across tracks.
    private var emitted: Int64 = 0

    init(node: AVAudioPlayerNode) {
        self.node = node
    }

    /// Queues `job` after the others, and schedules what fits ahead before returning, so the
    /// node has audio the moment it starts.
    func append(_ job: Job) {
        queue.sync {
            if jobs.isEmpty { next = job.start }
            jobs.append(job)
            fill()
        }
    }

    /// Drops every job. Call before stopping the node: whatever was already scheduled is then
    /// flushed by the stop, and nothing new arrives after it.
    func reset() {
        queue.sync {
            generation += 1
            jobs = []
            ahead = 0
            emitted = 0
        }
    }

    var isIdle: Bool { queue.sync { jobs.isEmpty } }

    private func fill() {
        while let job = jobs.first {
            let rate = job.decoder.processingFormat.sampleRate
            guard ahead < AVAudioFramePosition(rate * Self.aheadSeconds) else { return }
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(Self.chunkFrames), job.end - next))
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: job.decoder.processingFormat, frameCapacity: frames)
            else {
                jobs.removeFirst()
                job.onFinished()
                if let following = jobs.first { next = following.start }
                continue
            }
            job.decoder.framePosition = next
            job.decoder.markerOffset = emitted - next
            do {
                try job.decoder.read(into: buffer, frameCount: frames)
            } catch {
                buffer.frameLength = 0
            }
            if buffer.frameLength == 0 {
                // Unreadable: end the job here rather than spin.
                next = job.end
                continue
            }
            let count = AVAudioFramePosition(buffer.frameLength)
            next += count
            ahead += count
            emitted += count
            let last = next >= job.end
            if last {
                jobs.removeFirst()
                if let following = jobs.first { next = following.start }
            }
            let generation = self.generation
            let finished = last ? job.onFinished : nil
            node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataRendered) { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    guard generation == self.generation else { return }
                    self.ahead -= count
                    finished?()
                    self.fill()
                }
            }
        }
    }
}

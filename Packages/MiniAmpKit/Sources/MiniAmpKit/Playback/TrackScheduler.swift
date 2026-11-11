import AVFoundation

/// Schedules file segments back to back on one player node and maps the node's sample clock
/// back to "which segment, which frame".
///
/// Segments scheduled consecutively on the same node play with no gap between them, which is
/// what makes same-format transitions gapless. The node must be connected with the files'
/// processing format, so all segments in one session share a format.
@MainActor
final class TrackScheduler {
    struct Segment {
        /// Caller's identifier for the segment (the queue position it belongs to).
        let token: Int
        let file: AVAudioFile
        /// First frame of the file that this segment plays.
        let startFrame: AVAudioFramePosition
        let frameCount: AVAudioFramePosition
        /// Node sample time at which this segment starts playing.
        let nodeStart: AVAudioFramePosition
    }

    let node: AVAudioPlayerNode
    private(set) var segments: [Segment] = []
    private var scheduledEnd: AVAudioFramePosition = 0
    /// Bumped by reset(); completion callbacks from earlier sessions are ignored.
    private var session = 0

    /// Called on the main actor when a segment's last frame has been rendered (not when it's
    /// cancelled by reset). Rendered, not played back: in manual rendering mode the engine
    /// doesn't know the hardware's latency, so "played back" callbacks never arrive.
    var onSegmentFinished: ((Segment) -> Void)?

    init(node: AVAudioPlayerNode) {
        self.node = node
    }

    /// Stops the node and drops everything scheduled. The node's sample clock restarts at zero.
    func reset() {
        session += 1
        node.stop()
        segments = []
        scheduledEnd = 0
    }

    /// Schedules `file` from `startFrame` to its end, after everything already scheduled.
    @discardableResult
    func append(_ file: AVAudioFile, from startFrame: AVAudioFramePosition = 0, token: Int) -> Segment? {
        let start = min(max(startFrame, 0), file.length)
        let frames = file.length - start
        guard frames > 0 else { return nil }

        let segment = Segment(token: token, file: file, startFrame: start, frameCount: frames, nodeStart: scheduledEnd)
        let session = self.session
        let nodeStart = segment.nodeStart
        node.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(frames), at: nil,
                             completionCallbackType: .dataRendered) { [weak self] _ in
            Task { @MainActor in self?.finished(nodeStart: nodeStart, session: session) }
        }
        segments.append(segment)
        scheduledEnd += frames
        return segment
    }

    /// Frames played since the last reset, from the node's clock. Nil when the engine isn't rendering.
    var playedFrames: AVAudioFramePosition? {
        guard let nodeTime = node.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return nil }
        return max(playerTime.sampleTime, 0)
    }

    /// The segment playing now and the file frame it has reached.
    func currentPosition() -> (segment: Segment, frame: AVAudioFramePosition)? {
        guard let first = segments.first else { return nil }
        let played = playedFrames ?? first.nodeStart
        let segment = segments.last { $0.nodeStart <= played } ?? first
        let offset = min(max(played - segment.nodeStart, 0), segment.frameCount)
        return (segment, segment.startFrame + offset)
    }

    /// Whether anything is scheduled after the segment playing now.
    var hasQueuedSegment: Bool {
        guard let current = currentPosition()?.segment else { return false }
        return segments.contains { $0.nodeStart > current.nodeStart }
    }

    private func finished(nodeStart: AVAudioFramePosition, session: Int) {
        guard session == self.session, let index = segments.firstIndex(where: { $0.nodeStart == nodeStart })
        else { return }
        let segment = segments.remove(at: index)
        onSegmentFinished?(segment)
    }
}

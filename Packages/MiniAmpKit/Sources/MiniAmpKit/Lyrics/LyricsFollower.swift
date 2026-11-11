import Foundation
import Observation

/// Follows playback through synced lyrics: `position` changes as each line (and, in
/// word-timed lyrics, each word) starts.
///
/// Instead of polling, it sleeps until the next line or word is due, and starts over whenever
/// the timeline jumps or stops (seek, pause, resume, a new track). Nothing runs while paused,
/// or for plain lyrics.
@MainActor
@Observable
public final class LyricsFollower {
    public private(set) var position = LyricsPosition()
    public var lyrics: Lyrics? {
        didSet { if oldValue != lyrics { resync() } }
    }

    /// Where playback is, and whether it's moving.
    public typealias Clock = @MainActor () -> (time: Duration, isRunning: Bool)

    @ObservationIgnored private let clock: Clock
    @ObservationIgnored private var wakeup: Task<Void, Never>?

    /// Wakes this long after a line is due, so the clock has surely passed it.
    static let margin: Duration = .milliseconds(15)

    public init(clock: @escaping Clock) {
        self.clock = clock
    }

    /// Follows `player`, starting over on every seek, pause, resume, and track change.
    public convenience init(player: Player) {
        self.init { [weak player] in
            guard let player else { return (.zero, false) }
            return (player.exactTime, player.state == .playing)
        }
        observe(player)
    }

    isolated deinit { wakeup?.cancel() }

    /// Reads the clock and schedules the next change. Call it when playback jumps; the
    /// `player:` initializer does that itself.
    public func resync() {
        wakeup?.cancel()
        wakeup = nil
        guard let lyrics, lyrics.isSynced else {
            if position != LyricsPosition() { position = LyricsPosition() }
            return
        }
        let (now, running) = clock()
        let new = lyrics.position(at: now)
        if new != position { position = new }
        guard running, let next = lyrics.nextChange(after: now) else { return }
        let delay = max(next - now, .zero) + Self.margin
        wakeup = Task { [weak self] in
            try? await Task.sleep(for: delay, tolerance: .milliseconds(10))
            guard !Task.isCancelled else { return }
            self?.resync()
        }
    }

    private func observe(_ player: Player) {
        withObservationTracking {
            _ = player.state
            _ = player.seekCount
            _ = player.trackStarts
            _ = player.queue.currentIndex
        } onChange: { [weak self, weak player] in
            // Called before the change lands; look once it has.
            Task { @MainActor in
                guard let self, let player else { return }
                self.resync()
                self.observe(player)
            }
        }
    }
}

import Foundation
import Observation

/// Pauses playback after a while, or at the end of the current song.
@MainActor
@Observable
public final class SleepTimer {
    public enum Mode: Sendable, Equatable {
        case off
        /// Pauses at this moment.
        case until(Date)
        /// Stops when the current song ends.
        case endOfTrack
    }

    public private(set) var mode: Mode = .off

    public var isActive: Bool { mode != .off }

    @ObservationIgnored private let pause: @MainActor () -> Void
    @ObservationIgnored private let stopAfterTrack: @MainActor (Bool) -> Void
    @ObservationIgnored private var task: Task<Void, Never>?

    /// `pause` runs when the time is up; `stopAfterTrack` asks the player to stop (true) or
    /// carry on (false) at the end of the current song. Call `trackEnded()` when it has stopped.
    public init(pause: @escaping @MainActor () -> Void, stopAfterTrack: @escaping @MainActor (Bool) -> Void) {
        self.pause = pause
        self.stopAfterTrack = stopAfterTrack
    }

    /// Drives `player`: pauses it, or uses its stop-after-current-track.
    public convenience init(player: Player) {
        self.init(pause: { [weak player] in player?.pause() },
                  stopAfterTrack: { [weak player] in player?.stopsAfterCurrentTrack = $0 })
        player.onStoppedAfterTrack = { [weak self] in self?.trackEnded() }
    }

    /// Pauses after `duration`, replacing any timer already set.
    public func start(_ duration: Duration) {
        cancel()
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        mode = .until(Date().addingTimeInterval(seconds))
        task = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            self?.expire()
        }
    }

    /// Stops at the end of the current song, replacing any timer already set.
    public func stopAtEndOfTrack() {
        cancel()
        mode = .endOfTrack
        stopAfterTrack(true)
    }

    public func cancel() {
        task?.cancel()
        task = nil
        if mode == .endOfTrack { stopAfterTrack(false) }
        mode = .off
    }

    /// The player stopped at the end of the song, as asked.
    public func trackEnded() {
        guard mode == .endOfTrack else { return }
        mode = .off
    }

    /// Time left, for display; nil unless counting down.
    public func remaining(at now: Date = Date()) -> TimeInterval? {
        guard case .until(let deadline) = mode else { return nil }
        return max(deadline.timeIntervalSince(now), 0)
    }

    private func expire() {
        guard case .until = mode else { return }
        task = nil
        mode = .off
        pause()
    }
}

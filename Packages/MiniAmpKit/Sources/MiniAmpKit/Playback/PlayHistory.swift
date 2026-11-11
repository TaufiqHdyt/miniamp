import Foundation
import Observation
import os

/// Records plays: a track counts once it has been listened to for 30 seconds.
///
/// Only time spent playing counts. Paused, stopped, and the moments a new track takes to start
/// don't, and a seek adds nothing (the time it skips was never heard). The clock doesn't run
/// while the Mac sleeps. Each start of a track is its own play, so a track on repeat counts
/// every time round. A track shorter than the threshold counts once most of it has played.
///
/// The row is written when the threshold is reached, and its listening time is brought up to
/// date on pause and when the track ends.
@MainActor
public final class PlayHistory {
    public nonisolated static let threshold: Duration = .seconds(30)

    private let player: Player
    private let database: AppDatabase
    private var session: Session?
    private var checkTask: Task<Void, Never>?
    /// Database writes, one after another, so an update never overtakes the insert it updates.
    private var writes: Task<Void, Never>?

    static let log = Logger(subsystem: "dev.miniamp", category: "history")

    public init(player: Player, database: AppDatabase) {
        self.player = player
        self.database = database
        observe()
    }

    isolated deinit {
        checkTask?.cancel()
    }

    /// Listening time needed for a track of this length to count as played.
    nonisolated static func threshold(for duration: Duration) -> Duration {
        duration > .zero ? min(threshold, duration * 0.9) : threshold
    }

    // MARK: Internals

    /// One start of one track.
    private final class Session {
        let url: URL
        let start: Int
        let startedAt = Date()
        var listening = ListeningTime()
        /// The track's length, kept from while it was current: by the time a session
        /// finishes, the player already has the next track's.
        var duration: Duration = .zero
        var playId: Int64?
        var recorded = false

        init(url: URL, start: Int) {
            self.url = url
            self.start = start
        }
    }

    /// Syncs now and after each change to what playback is doing.
    private func observe() {
        withObservationTracking {
            _ = player.state
            _ = player.trackStarts
            _ = player.queue.current
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        sync()
    }

    private func sync() {
        let now = SuspendingClock.now
        let url = player.queue.current
        if let session, session.start != player.trackStarts || session.url != url {
            finish(session, at: now)
            self.session = nil
        }
        if session == nil, let url, player.state != .stopped {
            session = Session(url: url, start: player.trackStarts)
        }
        guard let session else {
            checkTask?.cancel()
            return
        }
        session.duration = player.duration
        let wasPlaying = session.listening.isRunning
        session.listening.set(running: player.state == .playing, at: now)
        if wasPlaying, !session.listening.isRunning { saveListening(session, at: now) }
        scheduleCheck(session, at: now)
    }

    /// Wakes when the session would reach the threshold, if it keeps playing.
    private func scheduleCheck(_ session: Session, at now: SuspendingClock.Instant) {
        checkTask?.cancel()
        guard !session.recorded, session.listening.isRunning else { return }
        let remaining = Self.threshold(for: session.duration) - session.listening.total(at: now)
        checkTask = Task { [weak self] in
            try? await Task.sleep(for: max(remaining, .zero), clock: .suspending)
            guard !Task.isCancelled, let self, self.session === session else { return }
            self.recordIfDue(session, at: .now)
            self.scheduleCheck(session, at: .now)
        }
    }

    private func recordIfDue(_ session: Session, at now: SuspendingClock.Instant) {
        let listened = session.listening.total(at: now)
        guard !session.recorded, listened >= Self.threshold(for: session.duration) else { return }
        session.recorded = true
        let url = session.url, startedAt = session.startedAt
        serially { [database] in
            do {
                session.playId = try await database.writer.write {
                    try Plays.record(url, playedAt: startedAt, listened: listened, $0)
                }
                if session.playId != nil {
                    Self.log.debug("played \(url.lastPathComponent, privacy: .public)")
                }
            } catch {
                Self.log.error("can't record a play: \(error, privacy: .public)")
            }
        }
    }

    private func saveListening(_ session: Session, at now: SuspendingClock.Instant) {
        guard session.recorded else { return }
        let listened = session.listening.total(at: now)
        serially { [database] in
            guard let id = session.playId else { return }
            do {
                try await database.writer.write { try Plays.update(id, listened: listened, $0) }
            } catch {
                Self.log.error("can't update a play: \(error, privacy: .public)")
            }
        }
    }

    /// The track changed or started again. It may have just crossed the threshold.
    private func finish(_ session: Session, at now: SuspendingClock.Instant) {
        checkTask?.cancel()
        session.listening.set(running: false, at: now)
        if session.recorded {
            saveListening(session, at: now)
        } else {
            recordIfDue(session, at: now)
        }
    }

    private func serially(_ work: @escaping @MainActor () async -> Void) {
        let previous = writes
        writes = Task {
            await previous?.value
            await work()
        }
    }
}

/// Time spent running, across any number of stops and starts.
struct ListeningTime {
    private var banked: Duration = .zero
    private var since: SuspendingClock.Instant?

    var isRunning: Bool { since != nil }

    mutating func set(running: Bool, at now: SuspendingClock.Instant) {
        if running, since == nil {
            since = now
        } else if !running, let since {
            banked += now - since
            self.since = nil
        }
    }

    func total(at now: SuspendingClock.Instant) -> Duration {
        banked + (since.map { now - $0 } ?? .zero)
    }
}

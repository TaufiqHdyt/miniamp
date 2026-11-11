import Foundation
import Testing
@testable import MiniAmpKit

/// Issue #24: the sleep timer.
@MainActor
@Suite struct SleepTimerTests {
    final class Calls {
        var pauses = 0
        var stopAfterTrack: [Bool] = []
    }

    func timer(_ calls: Calls) -> SleepTimer {
        SleepTimer(pause: { calls.pauses += 1 }, stopAfterTrack: { calls.stopAfterTrack.append($0) })
    }

    @Test func pausesWhenTheTimeIsUp() async {
        let calls = Calls()
        let timer = timer(calls)
        timer.start(.milliseconds(100))
        #expect(timer.isActive)
        #expect((timer.remaining() ?? 0) > 0)
        #expect(calls.pauses == 0)
        let deadline = ContinuousClock.now + .seconds(3)
        while calls.pauses == 0, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(calls.pauses == 1)
        #expect(timer.mode == .off)
        #expect(timer.remaining() == nil)
    }

    @Test func cancellingOrRestartingMeansNoPause() async throws {
        let calls = Calls()
        let timer = timer(calls)
        timer.start(.milliseconds(100))
        timer.cancel()
        timer.start(.milliseconds(150))
        timer.start(.seconds(60)) // replaces the 150 ms one
        try await Task.sleep(for: .milliseconds(400))
        #expect(calls.pauses == 0)
        #expect(timer.isActive)
        timer.cancel()
        #expect(!timer.isActive)
    }

    @Test func endOfTrackAsksThePlayerAndUndoesItWhenCancelled() {
        let calls = Calls()
        let timer = timer(calls)
        timer.stopAtEndOfTrack()
        #expect(timer.mode == .endOfTrack)
        #expect(calls.stopAfterTrack == [true])
        timer.cancel()
        #expect(calls.stopAfterTrack == [true, false])

        timer.stopAtEndOfTrack()
        timer.trackEnded()
        #expect(timer.mode == .off)
        // The player already reset itself; nothing more to undo.
        timer.cancel()
        #expect(calls.stopAfterTrack == [true, false, true])
    }

    @Test func switchingFromEndOfTrackToATimeUndoesTheStop() {
        let calls = Calls()
        let timer = timer(calls)
        timer.stopAtEndOfTrack()
        timer.start(.seconds(60))
        #expect(calls.stopAfterTrack == [true, false])
        if case .until = timer.mode {} else { Issue.record("expected a countdown, got \(timer.mode)") }
        timer.cancel()
    }
}

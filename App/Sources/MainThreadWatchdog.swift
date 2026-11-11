import Foundation
import os

/// Debug builds (or any build launched with `-logHangs YES`): logs whenever the main thread goes more than 50 ms without running, which
/// is when scrolling or clicking starts to feel stuck. `log stream --predicate 'category == "hang"'`.
enum MainThreadWatchdog {
    static let log = Logger(subsystem: "dev.miniamp", category: "hang")
    static let threshold: Duration = .milliseconds(50)

    @MainActor private(set) static var isRunning = false

    /// Call before a change on the main actor, then call the result: logs how long it took,
    /// including the layout and drawing that follow in the same turn of the run loop.
    @MainActor
    static func measure(_ what: String) -> @MainActor () -> Void {
        guard isRunning else { return {} }
        let start = ContinuousClock.now
        return {
            Task { @MainActor in
                log.notice("\(what, privacy: .public): \(Int((ContinuousClock.now - start) / .milliseconds(1))) ms")
            }
        }
    }

    @MainActor
    static func startIfWanted() {
        #if DEBUG
        start()
        #else
        if UserDefaults.standard.bool(forKey: "logHangs") { start() }
        #endif
    }

    @MainActor
    private static func start() {
        isRunning = true
        Task { @MainActor in
            let clock = ContinuousClock()
            var last = clock.now
            while true {
                try? await Task.sleep(for: .milliseconds(10))
                let now = clock.now
                let stall = now - last - .milliseconds(10)
                if stall > threshold {
                    log.notice("main thread stalled \(Int(stall / .milliseconds(1))) ms")
                }
                last = now
            }
        }
    }
}

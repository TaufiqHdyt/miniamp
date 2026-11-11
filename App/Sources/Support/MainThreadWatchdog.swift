import Foundation
import os

/// Debug builds (or any build launched with `-logHangs YES`): logs whenever the main thread is busy for more than 50 ms at a stretch, which
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

    /// Times each pass of the main run loop, from waking to going back to sleep. That is the
    /// time the main thread was busy, so it reports only real stalls and needs no timer of its
    /// own. (A sleep-and-check timer reported phantom 100 ms stalls whenever macOS coalesced the
    /// idle app's timers, and woke it a hundred times a second.)
    @MainActor
    private static func start() {
        isRunning = true
        let state = PassStart()
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0
        ) { _, activity in
            let now = ContinuousClock.now
            if activity == .afterWaiting {
                state.start = now
            } else if let start = state.start {
                state.start = nil
                let busy = now - start
                if busy > threshold { log.notice("main thread stalled \(Int(busy / .milliseconds(1))) ms") }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// When the current pass woke up. Touched only on the main thread, by the observer.
    private final class PassStart: @unchecked Sendable {
        var start: ContinuousClock.Instant?
    }
}

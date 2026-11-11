import Testing
@testable import MiniAmpKit

/// Issue #6: next, previous, shuffle, and repeat.
@Suite struct PlayQueueTests {
    /// Deterministic generator so shuffle tests are repeatable.
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    @Test func startsAtRequestedItem() {
        let q = PlayQueue(["a", "b", "c"], startAt: 1)
        #expect(q.current == "b")
        #expect(PlayQueue<String>().current == nil)
        #expect(PlayQueue(["a"], startAt: 9).current == "a")
    }

    @Test func repeatOffStopsAtEnd() {
        var q = PlayQueue(["a", "b"])
        let moved1 = q.advance(automatic: true); #expect(moved1)
        #expect(q.current == "b")
        let moved2 = q.advance(automatic: true); #expect(!moved2)
        let moved3 = q.advance(automatic: false); #expect(!moved3)
        #expect(q.current == "b")
    }

    @Test func repeatAllWraps() {
        var q = PlayQueue(["a", "b"], startAt: 1)
        q.repeatMode = .all
        let moved4 = q.advance(automatic: true); #expect(moved4)
        #expect(q.current == "a")
        let moved5 = q.goBack(); #expect(moved5)
        #expect(q.current == "b")
    }

    @Test func repeatOneReplaysAutomaticallyButUserNextSkips() {
        var q = PlayQueue(["a", "b"])
        q.repeatMode = .one
        #expect(q.upcoming(automatic: true) == 0)
        q.advance(automatic: true)
        #expect(q.current == "a")
        q.advance(automatic: false)
        #expect(q.current == "b")
        q.advance(automatic: false) // wraps in repeat-one too
        #expect(q.current == "a")
    }

    @Test func previousStopsAtStartWithoutRepeat() {
        var q = PlayQueue(["a", "b"])
        let moved6 = q.goBack(); #expect(!moved6)
        #expect(q.current == "a")
    }

    @Test func shuffleKeepsCurrentFirstAndPlaysEverythingOnce() {
        var rng = SeededGenerator(state: 42)
        let items = (0..<20).map(String.init)
        var q = PlayQueue(items, startAt: 7)
        q.setShuffle(true, using: &rng)
        #expect(q.current == "7")
        #expect(q.position == 0)
        #expect(Set(q.order) == Set(items.indices))
        #expect(q.order != Array(items.indices))

        var played = [q.current!]
        while q.advance(automatic: true) { played.append(q.current!) }
        #expect(played.count == items.count)
        #expect(Set(played) == Set(items))
    }

    @Test func unshuffleRestoresNaturalOrderAtCurrentItem() {
        var rng = SeededGenerator(state: 1)
        var q = PlayQueue(["a", "b", "c", "d"], startAt: 0)
        q.setShuffle(true, using: &rng)
        q.advance(automatic: false)
        let now = q.current
        q.setShuffle(false, using: &rng)
        #expect(q.current == now)
        #expect(q.order == [0, 1, 2, 3])
    }

    @Test func jumpToItem() {
        var q = PlayQueue(["a", "b", "c"])
        q.jump(toItem: 2)
        #expect(q.current == "c")
    }
}

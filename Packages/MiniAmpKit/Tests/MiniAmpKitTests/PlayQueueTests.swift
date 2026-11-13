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

    // MARK: Play Next, Play Last, Up Next edits

    static func upcoming(_ q: PlayQueue<String>) -> [String] {
        guard let p = q.position else { return [] }
        return q.order[(p + 1)...].map { q.items[$0] }
    }

    @Test func playNextGoesAfterCurrentAndPlayLastAtTheEnd() {
        var q = PlayQueue(["a", "b", "c"], startAt: 0)
        q.insert(["x", "y"], next: true)
        q.insert(["z"], next: false)
        #expect(q.current == "a")
        #expect(Self.upcoming(q) == ["x", "y", "b", "c", "z"])
        // Items already there keep their indices.
        #expect(Array(q.items.prefix(3)) == ["a", "b", "c"])
    }

    @Test func insertingIntoAnEmptyQueueStartsIt() {
        var q = PlayQueue<String>()
        q.insert(["a", "b"], next: true)
        #expect(q.current == "a")
        #expect(Self.upcoming(q) == ["b"])
    }

    @Test func editsSurviveShuffleOnAndOff() {
        var q = PlayQueue(["a", "b", "c", "d"], startAt: 1)
        q.insert(["x"], next: true)
        q.remove(atPosition: 3) // "c"
        var rng = SeededGenerator(state: 7)
        q.setShuffle(true, using: &rng)
        #expect(q.current == "b")
        #expect(Set(Self.upcoming(q)) == ["x", "d", "a"].reduce(into: Set()) { $0.insert($1) })
        q.setShuffle(false)
        #expect(q.current == "b")
        #expect(q.order.map { q.items[$0] } == ["a", "b", "x", "d"])
    }

    @Test func playNextWhileShuffledComesNext() {
        var q = PlayQueue(["a", "b", "c", "d"], startAt: 0)
        var rng = SeededGenerator(state: 3)
        q.setShuffle(true, using: &rng)
        q.insert(["x"], next: true)
        #expect(Self.upcoming(q).first == "x")
    }

    @Test func removeKeepsTheCurrentItem() {
        var q = PlayQueue(["a", "b", "c"], startAt: 1)
        q.remove(atPosition: 1)
        #expect(q.current == "b")
        q.remove(atPosition: 0)
        #expect(q.current == "b")
        #expect(q.position == 0)
        #expect(Self.upcoming(q) == ["c"])
    }

    @Test func moveToNext() {
        var q = PlayQueue(["a", "b", "c", "d"], startAt: 0)
        q.moveToNext(fromPosition: 3)
        #expect(Self.upcoming(q) == ["d", "b", "c"])
        q.setShuffle(true)
        q.setShuffle(false)
        #expect(q.order.map { q.items[$0] } == ["a", "d", "b", "c"])
    }

    @Test func dragReorders() {
        var q = PlayQueue(["a", "b", "c", "d", "e"], startAt: 1)
        // "e" up to before "c".
        q.move(fromPositions: [4], toPosition: 2)
        #expect(Self.upcoming(q) == ["e", "c", "d"])
        // "e" and "c" down to the end.
        q.move(fromPositions: [2, 3], toPosition: 5)
        #expect(Self.upcoming(q) == ["d", "e", "c"])
        // The current song and those before it don't move, and nothing goes before it.
        q.move(fromPositions: [0, 1], toPosition: 4)
        q.move(fromPositions: [4], toPosition: 0)
        #expect(q.current == "b")
        #expect(q.order.map { q.items[$0] } == ["a", "b", "c", "d", "e"])
        // Unshuffled, the new order stays when shuffle goes on and off.
        q.move(fromPositions: [4], toPosition: 2)
        q.setShuffle(true)
        q.setShuffle(false)
        #expect(q.order.map { q.items[$0] } == ["a", "b", "e", "c", "d"])
    }
}

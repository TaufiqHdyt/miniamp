/// Play order over a list of items, with shuffle and repeat. Pure value type; Player drives it.
public struct PlayQueue<Item: Sendable & Equatable>: Sendable, Equatable {
    public enum Repeat: String, Sendable, CaseIterable {
        case off, all, one
    }

    public private(set) var items: [Item]
    /// Play order: indices into `items`. Natural order (with any edits) unless shuffled.
    public private(set) var order: [Int]
    /// Index into `order` of the current item; nil when empty.
    public private(set) var position: Int?
    public private(set) var isShuffled = false
    public var repeatMode: Repeat = .off
    /// The order unshuffled: what `order` goes back to when shuffle is turned off. Songs added
    /// or moved later are where they were put; removed ones are gone.
    ///
    /// An item keeps its index in `items` for as long as the queue lasts (the player tags
    /// what it has scheduled by it), so adding appends to `items` and removing only takes the
    /// index out of the orders.
    private var natural: [Int]

    public init(_ items: [Item] = [], startAt index: Int = 0) {
        self.items = items
        order = Array(items.indices)
        natural = order
        position = items.isEmpty ? nil : min(max(index, 0), items.count - 1)
    }

    public var isEmpty: Bool { items.isEmpty }

    /// Index into `items` of the current item.
    public var currentIndex: Int? { position.map { order[$0] } }
    public var current: Item? { currentIndex.map { items[$0] } }

    /// The order position that plays after the current one.
    ///
    /// `automatic` is the end-of-track case, where repeat-one replays the same item. A user's
    /// "next" skips ahead even in repeat-one, and wraps around in either repeat mode.
    public func upcoming(automatic: Bool) -> Int? {
        guard let position else { return nil }
        if automatic && repeatMode == .one { return position }
        if position + 1 < order.count { return position + 1 }
        return repeatMode == .off ? nil : 0
    }

    public func item(atPosition p: Int) -> Item { items[order[p]] }

    /// Moves to the next item. Returns false at the end of the queue with repeat off.
    @discardableResult
    public mutating func advance(automatic: Bool) -> Bool {
        guard let next = upcoming(automatic: automatic) else { return false }
        position = next
        return true
    }

    /// Moves to the previous item, wrapping to the end when repeating. Returns false at the start.
    @discardableResult
    public mutating func goBack() -> Bool {
        guard let position else { return false }
        if position > 0 {
            self.position = position - 1
            return true
        }
        guard repeatMode != .off, order.count > 1 else { return false }
        self.position = order.count - 1
        return true
    }

    /// Jumps to an order position, as returned by `upcoming(automatic:)`.
    public mutating func move(toPosition p: Int) {
        precondition(order.indices.contains(p))
        position = p
    }

    /// Jumps to an item by its index in `items`.
    public mutating func jump(toItem index: Int) {
        guard let p = order.firstIndex(of: index) else { return }
        position = p
    }

    /// Shuffling keeps the current item playing and puts it first, so everything else plays
    /// once before the order repeats. Unshuffling restores natural order at the current item.
    public mutating func setShuffle<R: RandomNumberGenerator>(_ on: Bool, using rng: inout R) {
        guard on != isShuffled else { return }
        isShuffled = on
        let current = currentIndex
        if on {
            var rest = natural.filter { $0 != current }
            rest.shuffle(using: &rng)
            order = (current.map { [$0] } ?? []) + rest
            position = order.isEmpty ? nil : 0
        } else {
            order = natural
            position = current.flatMap { order.firstIndex(of: $0) }
        }
    }

    public mutating func setShuffle(_ on: Bool) {
        var rng = SystemRandomNumberGenerator()
        setShuffle(on, using: &rng)
    }

    // MARK: Editing

    /// Adds `new` right after the current item (Play Next) or at the end (Play Last), in the
    /// order given, shuffled or not. An empty queue starts at the first of them.
    public mutating func insert(_ new: [Item], next: Bool) {
        guard !new.isEmpty else { return }
        let added = Array(items.count ..< items.count + new.count)
        items += new
        guard let position else {
            order = added
            natural = added
            self.position = 0
            return
        }
        if next {
            let current = order[position]
            order.insert(contentsOf: added, at: position + 1)
            natural.insert(contentsOf: added, at: (natural.firstIndex(of: current) ?? natural.count - 1) + 1)
        } else {
            order += added
            natural += added
        }
    }

    /// Takes the item at an order position out of the queue. The current item stays.
    public mutating func remove(atPosition p: Int) {
        guard let position, order.indices.contains(p), p != position else { return }
        let item = order.remove(at: p)
        natural.removeAll { $0 == item }
        if p < position { self.position = position - 1 }
    }

    /// Moves the item at an order position to play right after the current one.
    public mutating func moveToNext(fromPosition p: Int) {
        guard let position, order.indices.contains(p), p != position else { return }
        let item = order[p]
        remove(atPosition: p)
        guard let now = self.position else { return }
        let current = order[now]
        order.insert(item, at: now + 1)
        natural.insert(item, at: (natural.firstIndex(of: current) ?? natural.count - 1) + 1)
    }
}

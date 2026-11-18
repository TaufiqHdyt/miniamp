import Foundation

/// The order the online lyrics providers are tried in, and which are on. Every provider
/// miniamp knows is listed once: one added in a later version joins at the end, in its
/// default state; one no longer known is dropped.
public struct LyricsProviderSettings: Sendable, Equatable, Codable {
    public struct Entry: Sendable, Equatable, Codable, Identifiable {
        public var provider: LyricsProviderID
        public var isOn: Bool
        public var id: LyricsProviderID { provider }
    }

    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        var seen = Set<LyricsProviderID>()
        var kept = entries.filter { seen.insert($0.provider).inserted }
        for provider in LyricsProviderID.allCases where !seen.contains(provider) {
            kept.append(Entry(provider: provider, isOn: provider.isOnByDefault))
        }
        self.entries = kept
    }

    public init(from decoder: any Decoder) throws {
        // Unknown provider names (from a later version's backup) are skipped, not fatal.
        struct Loose: Decodable { var provider: String; var isOn: Bool }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let loose = try container.decode([Loose].self, forKey: .entries)
        self.init(entries: loose.compactMap { e in LyricsProviderID(rawValue: e.provider).map { Entry(provider: $0, isOn: e.isOn) } })
    }

    /// The providers that are on, in order.
    public var enabled: [LyricsProviderID] { entries.filter(\.isOn).map(\.provider) }

    public func isOn(_ provider: LyricsProviderID) -> Bool { entries.first { $0.provider == provider }?.isOn ?? false }

    public mutating func set(_ provider: LyricsProviderID, on: Bool) {
        guard let index = entries.firstIndex(where: { $0.provider == provider }) else { return }
        entries[index].isOn = on
    }

    /// Moves a provider up (negative) or down (positive) the list, stopping at the ends.
    public mutating func move(_ provider: LyricsProviderID, by offset: Int) {
        guard let from = entries.firstIndex(where: { $0.provider == provider }) else { return }
        let to = min(max(from + offset, 0), entries.count - 1)
        guard to != from else { return }
        entries.insert(entries.remove(at: from), at: to)
    }

    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { entries[$0] }
        let before = source.filter { $0 < destination }.count
        entries = entries.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        entries.insert(contentsOf: moving, at: destination - before)
    }
}

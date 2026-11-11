import Foundation
import GRDB

/// Playlist edits. Positions run 0, 1, 2… with no gaps; every edit renumbers the playlist it
/// touches, which is cheap at playlist sizes and keeps "insert before row n" simple.
public enum Playlists {
    public enum EditError: Error, CustomStringConvertible {
        case noSuchPlaylist(Int64)
        case blankName

        public var description: String {
            switch self {
            case .noSuchPlaylist(let id): "playlist \(id) doesn't exist"
            case .blankName: "a playlist needs a name"
            }
        }
    }

    /// Creates a playlist holding `trackIds`, in that order. Returns its id.
    @discardableResult
    public static func create(named name: String, trackIds: [Int64] = [], _ db: Database) throws -> Int64 {
        guard let name = Optional(name).nonBlank else { throw EditError.blankName }
        let now = Date()
        var playlist = Playlist(name: name, createdAt: now, updatedAt: now)
        try playlist.insert(db)
        let id = playlist.id!
        try add(trackIds, to: id, db)
        return id
    }

    public static func rename(_ id: Int64, to name: String, _ db: Database) throws {
        guard let name = Optional(name).nonBlank else { throw EditError.blankName }
        try db.execute(sql: "UPDATE playlist SET name = ?, updatedAt = ? WHERE id = ?", arguments: [name, Date(), id])
        guard db.changesCount > 0 else { throw EditError.noSuchPlaylist(id) }
    }

    /// Deletes the playlist and its entries (the tracks stay in the library).
    public static func delete(_ id: Int64, _ db: Database) throws {
        _ = try Playlist.deleteOne(db, key: id)
    }

    /// Adds `trackIds` before the entry now at `index`, or at the end when `index` is nil or past it.
    public static func add(_ trackIds: [Int64], to id: Int64, at index: Int? = nil, _ db: Database) throws {
        guard !trackIds.isEmpty else { return }
        var items = try itemIds(in: id, db)
        let at = min(max(index ?? items.count, 0), items.count)
        var added: [Int64] = []
        for trackId in trackIds {
            var item = PlaylistItem(playlistId: id, trackId: trackId, position: 0)
            try item.insert(db)
            added.append(item.id!)
        }
        items.insert(contentsOf: added, at: at)
        try renumber(id, items, db)
    }

    /// Removes these entries (playlist item ids, as `TrackInfo.playlistItemId` gives them).
    public static func remove(_ itemIds: [Int64], from id: Int64, _ db: Database) throws {
        guard !itemIds.isEmpty else { return }
        let gone = Set(itemIds)
        try PlaylistItem.filter(keys: Array(gone)).filter(Column("playlistId") == id).deleteAll(db)
        try renumber(id, try self.itemIds(in: id, db).filter { !gone.contains($0) }, db)
    }

    /// Moves these entries, keeping their order, to just before the entry now at `index`
    /// (counted before the move, as a table's drop row is). Past the end moves them to the end.
    public static func move(_ itemIds: [Int64], in id: Int64, to index: Int, _ db: Database) throws {
        let items = try self.itemIds(in: id, db)
        let moving = Set(itemIds)
        let moved = items.filter { moving.contains($0) }
        guard !moved.isEmpty else { return }
        let clamped = min(max(index, 0), items.count)
        var rest = items.filter { !moving.contains($0) }
        let at = clamped - items[..<clamped].filter { moving.contains($0) }.count
        rest.insert(contentsOf: moved, at: at)
        try renumber(id, rest, db)
    }

    /// The playlist's entries, in order.
    static func itemIds(in id: Int64, _ db: Database) throws -> [Int64] {
        guard try Playlist.exists(db, key: id) else { throw EditError.noSuchPlaylist(id) }
        return try Int64.fetchAll(db, sql: "SELECT id FROM playlistItem WHERE playlistId = ? ORDER BY position, id",
                                  arguments: [id])
    }

    /// Gives `items` positions 0, 1, 2… (only the ones that changed are written) and marks the playlist updated.
    private static func renumber(_ id: Int64, _ items: [Int64], _ db: Database) throws {
        let current = Dictionary(uniqueKeysWithValues: try Row.fetchAll(
            db, sql: "SELECT id, position FROM playlistItem WHERE playlistId = ?", arguments: [id]
        ).map { (row: Row) -> (Int64, Int) in (row["id"], row["position"]) })
        let update = try db.makeStatement(sql: "UPDATE playlistItem SET position = ? WHERE id = ?")
        for (position, item) in items.enumerated() where current[item] != position {
            try update.execute(arguments: [position, item])
        }
        try db.execute(sql: "UPDATE playlist SET updatedAt = ? WHERE id = ?", arguments: [Date(), id])
    }
}

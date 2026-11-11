import GRDB

enum Schema {
    /// Tracks, albums, artists, playlists, play history, the folders the library watches,
    /// and an FTS5 index over track, artist, album, and genre names kept current by triggers.
    static func v1(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE libraryFolder (
                id INTEGER PRIMARY KEY,
                path TEXT NOT NULL UNIQUE,          -- canonical (realpath) form, as FSEvents reports it
                bookmark BLOB NOT NULL,             -- security-scoped in the sandbox
                addedAt DATETIME NOT NULL,
                lastScannedAt DATETIME
            );

            CREATE TABLE artist (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL UNIQUE COLLATE NOCASE
            );

            CREATE TABLE album (
                id INTEGER PRIMARY KEY,
                title TEXT NOT NULL COLLATE NOCASE,
                artistId INTEGER REFERENCES artist(id) ON DELETE SET NULL, -- album artist
                year INTEGER,
                artworkKey TEXT
            );
            -- One album per title and album artist; an album with no artist is still unique.
            CREATE UNIQUE INDEX album_identity ON album(title, ifnull(artistId, 0));
            CREATE INDEX album_artist ON album(artistId);

            CREATE TABLE track (
                id INTEGER PRIMARY KEY,
                folderId INTEGER NOT NULL REFERENCES libraryFolder(id) ON DELETE CASCADE,
                path TEXT NOT NULL UNIQUE,
                fileSize INTEGER NOT NULL,
                modifiedAt DOUBLE NOT NULL,         -- content modification, seconds since 1970
                title TEXT NOT NULL,                -- the file name when the file has no title tag
                artistId INTEGER REFERENCES artist(id) ON DELETE SET NULL,
                albumId INTEGER REFERENCES album(id) ON DELETE SET NULL,
                genre TEXT,
                year INTEGER,
                trackNumber INTEGER,
                discNumber INTEGER,
                durationMs INTEGER NOT NULL,
                sampleRate INTEGER NOT NULL,
                bitsPerSample INTEGER,              -- NULL for lossy formats
                channels INTEGER NOT NULL,
                bitrateKbps INTEGER NOT NULL,
                codec TEXT NOT NULL,
                artworkKey TEXT,                    -- see ArtworkCache
                addedAt DATETIME NOT NULL,
                isEvicted BOOLEAN NOT NULL DEFAULT 0 -- data only in the cloud; see CloudFiles
            );
            CREATE INDEX track_folder ON track(folderId);
            CREATE INDEX track_artist ON track(artistId);
            CREATE INDEX track_album ON track(albumId, discNumber, trackNumber);

            CREATE TABLE playlist (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                createdAt DATETIME NOT NULL,
                updatedAt DATETIME NOT NULL
            );

            CREATE TABLE playlistItem (
                id INTEGER PRIMARY KEY,
                playlistId INTEGER NOT NULL REFERENCES playlist(id) ON DELETE CASCADE,
                trackId INTEGER NOT NULL REFERENCES track(id) ON DELETE CASCADE,
                position INTEGER NOT NULL
            );
            CREATE INDEX playlistItem_order ON playlistItem(playlistId, position);
            CREATE INDEX playlistItem_track ON playlistItem(trackId);

            CREATE TABLE play (
                id INTEGER PRIMARY KEY,
                trackId INTEGER NOT NULL REFERENCES track(id) ON DELETE CASCADE,
                playedAt DATETIME NOT NULL,
                listenedMs INTEGER NOT NULL
            );
            CREATE INDEX play_track ON play(trackId);
            CREATE INDEX play_time ON play(playedAt);

            -- Search index. rowid = track.id. Diacritics are folded, so "bjork" finds "Björk".
            CREATE VIRTUAL TABLE trackSearch USING fts5(
                title, artist, album, albumArtist, genre,
                tokenize = 'unicode61 remove_diacritics 2',
                prefix = '1 2 3'
            );

            CREATE TRIGGER track_search_insert AFTER INSERT ON track BEGIN
                INSERT INTO trackSearch(rowid, title, artist, album, albumArtist, genre) VALUES (
                    new.id, new.title,
                    (SELECT name FROM artist WHERE id = new.artistId),
                    (SELECT title FROM album WHERE id = new.albumId),
                    (SELECT artist.name FROM album JOIN artist ON artist.id = album.artistId WHERE album.id = new.albumId),
                    new.genre);
            END;
            CREATE TRIGGER track_search_update AFTER UPDATE ON track BEGIN
                DELETE FROM trackSearch WHERE rowid = old.id;
                INSERT INTO trackSearch(rowid, title, artist, album, albumArtist, genre) VALUES (
                    new.id, new.title,
                    (SELECT name FROM artist WHERE id = new.artistId),
                    (SELECT title FROM album WHERE id = new.albumId),
                    (SELECT artist.name FROM album JOIN artist ON artist.id = album.artistId WHERE album.id = new.albumId),
                    new.genre);
            END;
            CREATE TRIGGER track_search_delete AFTER DELETE ON track BEGIN
                DELETE FROM trackSearch WHERE rowid = old.id;
            END;
            -- Renames re-index the affected tracks (the no-op update fires track_search_update).
            CREATE TRIGGER artist_search_rename AFTER UPDATE OF name ON artist BEGIN
                UPDATE track SET id = id
                WHERE artistId = new.id OR albumId IN (SELECT id FROM album WHERE artistId = new.id);
            END;
            CREATE TRIGGER album_search_rename AFTER UPDATE OF title, artistId ON album BEGIN
                UPDATE track SET id = id WHERE albumId = new.id;
            END;
            """)
    }
}

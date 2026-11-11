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

    /// ReplayGain, in its own table so the track rows (read for every list) stay as they are.
    ///
    /// A track can have two rows: what its tags say (`source` 'tags', rewritten whenever its
    /// tags are read) and what miniamp measured ('scan', see LoudnessScanner). Tags win.
    /// Gains are in dB, peaks linear (1.0 is full scale).
    static func v2(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE replayGain (
                trackId INTEGER NOT NULL REFERENCES track(id) ON DELETE CASCADE,
                source TEXT NOT NULL CHECK (source IN ('tags', 'scan')),
                trackGain DOUBLE NOT NULL,
                trackPeak DOUBLE,
                albumGain DOUBLE,
                albumPeak DOUBLE,
                PRIMARY KEY (trackId, source)
            ) WITHOUT ROWID;

            -- Tracks scanned before this have never had their ReplayGain tags read. Forgetting
            -- when their files changed makes the next scan read every file once more.
            UPDATE track SET modifiedAt = 0;
            """)
    }

    /// Lyrics from LRCLIB, one row per track asked about: what it returned, or that it had
    /// nothing (`lrclibId` NULL), so the next play doesn't ask again. Lyrics that come with
    /// the file (a sidecar .lrc or the tags) are read from it each time and never stored.
    static func v3(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE onlineLyrics (
                trackId INTEGER PRIMARY KEY REFERENCES track(id) ON DELETE CASCADE,
                lrclibId INTEGER,                   -- NULL when LRCLIB had nothing
                syncedLyrics TEXT,
                plainLyrics TEXT,
                instrumental BOOLEAN NOT NULL DEFAULT 0,
                fetchedAt DATETIME NOT NULL
            );
            """)
    }
}

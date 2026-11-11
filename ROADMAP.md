# miniamp roadmap

A native macOS music player for a local library. It plays FLAC, MP3, ALAC, and AAC (M4A) at each file's original sample rate, with no resampling whenever the output device supports that rate.

## Stack

- **Language and UI:** Swift, SwiftUI, with AppKit (`NSTableView`) for large track lists if needed
- **Decoding:** `AVAudioFile`, which handles all four formats natively
- **Playback:** `AVAudioEngine` with `AVAudioPlayerNode`
- **Output control:** Core Audio HAL properties for sample rate, physical format, and hog mode
- **Metadata:** TagLib (read and write)
- **Database:** SQLite through GRDB, with FTS5 for search

## Ground rules

- **Two signal paths.** Bit-perfect mode connects the player node straight to the output. DSP mode adds EQ and gain. Anything that alters samples (EQ, ReplayGain, crossfade) lives only in DSP mode, and the UI always shows which mode is active.
- **Query, don't assume.** Read the device's supported sample rates at runtime. The built-in headphone jack on recent MacBook Pros tops out at 96 kHz; a USB DAC may go higher.
- **Honest indicator.** The quality label shows the file's format and the device's live rate, and says plainly when playback is resampled.
- **Play counting.** A play counts after 30 seconds of actual listening. Paused and seeking time doesn't count.

## Milestones

### M1: Playback proof of concept

This carries most of the technical risk, so it comes first.

- [ ] Xcode project, app target, GRDB and TagLib dependencies
- [ ] Play one file of each format (FLAC, MP3, ALAC, AAC) through `AVAudioEngine`
- [ ] Switch the device's nominal sample rate to match the file, and wait for the change notification before starting
- [ ] Set the device's physical format to its highest bit depth at that rate
- [ ] Connect nodes using the file's processing format so the mixer converts nothing

**Done when:** a 96 kHz FLAC plays through the headphone jack and Audio MIDI Setup shows 96 kHz, then a 44.1 kHz file switches it back.

### M2: Playback core

- [ ] Queue with next, previous, shuffle, and repeat
- [ ] Seek and position reporting
- [ ] Gapless transitions between tracks with the same format
- [ ] Output device selection, and handling for device changes (unplugged headphones, DAC connected)
- [ ] Fallback when the device can't do the file's rate: pick the integer half rate where possible (176.4 to 88.2, 192 to 96) and resample at high quality
- [ ] Optional hog mode
- [ ] Volume through the device, not through sample scaling

**Done when:** an album plays gaplessly, and a 192 kHz file on the built-in jack plays at 96 kHz and reports itself as resampled.

### M3: Library

- [ ] Database schema: tracks, albums, artists, playlists, play history
- [ ] Folder picker with security-scoped bookmarks
- [ ] Background scanner that reads tags, duration, sample rate, and bit depth
- [ ] FSEvents watcher that rescans only changed files
- [ ] Artwork extraction with an on-disk thumbnail cache
- [ ] Full-text search

**Done when:** a 10,000-track folder scans without blocking the UI, and adding a file to the folder shows up without a manual rescan.

### M4: Interface

- [ ] Sidebar with artists, albums, songs, and playlists
- [ ] Track table with sorting
- [ ] Now-playing view with cover art and queue
- [ ] Quality label and bit-perfect indicator
- [ ] Search field
- [ ] Sleep timer

**Done when:** the app is usable day to day without touching a debugger.

### M5: System integration and library tools

- [ ] Media keys and Control Center through `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter`
- [ ] Playlist create, edit, and reorder
- [ ] M3U8 export
- [ ] Metadata editing with TagLib, followed by a rescan of the edited file
- [ ] Play history recording with the 30-second rule

**Done when:** media keys work with the app in the background, and a tag edit survives a full rescan.

### M6: DSP mode

- [ ] Engine graph switch between bit-perfect and DSP mode
- [ ] Multiband EQ with `AVAudioUnitEQ` and presets
- [ ] ReplayGain: read existing tags and apply track or album gain
- [ ] ReplayGain scanning with libebur128 (EBU R128), results stored in the database

**Done when:** turning bit-perfect mode on removes every DSP node from the graph, and the indicator reflects it.

### M7: Lyrics and listening stats

- [ ] LRC parser, including word-timed enhanced LRC
- [ ] Embedded lyrics and sidecar `.lrc` files
- [ ] Synced lyrics view that follows playback position
- [ ] Online lookup through LRCLIB for tracks with no lyrics
- [ ] Listening stats and a yearly recap with Swift Charts

**Done when:** a track with a sidecar `.lrc` scrolls in sync, including after a seek.

### M8: Later

Unordered. Pick these up as interest dictates.

- [ ] Network sources: Subsonic and WebDAV clients with a local cache and Keychain credentials
- [ ] Duplicate review, by tags and duration first, Chromaprint fingerprints later
- [ ] Menu bar mini player and a WidgetKit widget
- [ ] Crossfade with beat detection (DSP mode only)
- [ ] DSD playback over DoP to compatible DACs
- [ ] Backup and restore of the database and settings
- [ ] Lyric translation and romanization
- [ ] Artwork-based tinting

## Out of scope

- Downloading from streaming services
- Extension repositories
- Haptics and concert listings

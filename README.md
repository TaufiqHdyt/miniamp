# miniamp

A native macOS music player for a local library. See [ROADMAP.md](ROADMAP.md).

## Development setup

Requirements: Apple silicon Mac, [Xcode](https://apps.apple.com/app/xcode/id497799835), [Homebrew](https://brew.sh).

```sh
sudo xcode-select -s /Applications/Xcode.app   # once, after installing Xcode
make bootstrap   # installs xcodegen and lame (for test fixtures); generates MiniAmp.xcodeproj
make open        # opens the project in Xcode
```

Other targets:

| Command        | What it does                                         |
|----------------|------------------------------------------------------|
| `make doctor`  | Checks that Xcode and XcodeGen are present           |
| `make project` | Regenerates `MiniAmp.xcodeproj` from `project.yml`   |
| `make build`   | Builds the app from the command line                 |
| `make clean`   | Deletes the app's `build/` and the Kit's `.build` (`make clean build` builds from scratch) |
| `make run`     | Builds, launches the app, and streams its trace logs here (`VERBOSE=1` adds system messages) |
| `make test`    | Runs the `MiniAmpKit` tests (needs Xcode)            |
| `make fixtures`| Writes 10 s test tones in every format, plus a mono file, to `Fixtures/` |
| `make ctl ARGS="devices"` | Shows the output device's rates and physical formats |
| `make ctl ARGS="play <file>..."` | Plays files as a queue outside the sandbox and prints the signal path. Options: `--seconds N`, `--seek S`, `--device NAME`, `--hog`, `--repeat off\|all\|one`, `--shuffle`, `--dsp`, `--eq PRESET`, `--gain DB`, `--lyrics` (prints each synced line as the player reaches it; `--lyrics-offset MS` shifts them) |
| `make ctl ARGS="lyrics [--online] <file>"` | Shows a file's lyrics (sidecar `.lrc` or tags) and where they came from; `--online` asks LRCLIB when it has none |
| `make ctl ARGS="volume [0-1]"` | Reads or sets the default output device's own volume |
| `make ctl ARGS="library scan <folder>"` | Scans a folder into a scratch library (`$TMPDIR/miniampctl`, or `--db PATH`) and reports scan time and the longest main-actor stall. Also `library search <words>`, `library watch` (follows file changes live), `library stats`, `library history` (the last 50 plays), and `library recap [YEAR]` (listening stats), `library duplicates [--sound]`, `library backup <file>` and `library restore <file>` |
| `make ctl ARGS="fingerprint <file> [<other>]"` | A file's Chromaprint fingerprint, or how alike two files sound |
| `make library-bench` | Generates a 10,000-track fake library in `/tmp/miniamp-library` (`TRACKS=N`), then scans it cold and again with nothing changed |
| `make bench`   | Measures CPU, energy impact, wakeups, and memory while playing silent files in each format (`SECS=N` per case, default 30). Quit miniamp first |
| `make app-bench` | The same for the app: idle, then playing with Up Next, Lyrics, the inspector closed, and the visualizer, on a scratch library in its container (`SECS=N`, `CONFIG=Release`). Needs the screen on: a covered window or a locked screen draws nothing. Quit miniamp first |

`MiniAmp.xcodeproj` is generated and not committed. Edit `project.yml` and run `make project` instead of changing build settings in Xcode.

## Layout

```
App/Sources/              SwiftUI app target (thin; UI only)
  App/                    Entry point, shared state, menus, settings, preferences
  Library/                Main window, sidebar, browsing, the track table, Get Info, listening stats, duplicates
  NowPlaying/             The inspector (Up Next with the song playing, Lyrics), full-size lyrics, the visualizer
  Player/                 Player bar, menu bar mini player, seek bar, app volume, output picker, equalizer, Control Center
  Support/                Artwork, formatting, the spectrum view, window visibility, hang logging, the widget's data
Shared/                   Compiled into the app and the widget: the now-playing snapshot, playback intents
Widget/                   The Now Playing widget (WidgetKit extension)
Packages/MiniAmpKit/      Everything testable: playback, library, database
  Sources/TagLibBridge    C++ shim with a C API over TagLib, which is built from source with it (vendor/; see VENDORED.txt)
  Sources/CEBUR128        libebur128 (EBU R128 loudness), vendored unmodified
  Sources/CChromaprint    Chromaprint (audio fingerprints, for duplicates), vendored unmodified; see VENDORED.txt
  Sources/CDSD            DSD playback's inner loops (DoP packing, the PCM filter), optimized in Debug too
  Sources/MiniAmpKit/
    Audio/                Core Audio: devices, the hardware output (and its tap for the visualizer), format selection, DSD files
    Playback/             Player, queue, gapless scheduling, crossfade, the spectrum analyser, DSP mode and EQ, sleep timer, play history
    Library/              Database records, scanning, tag reading and writing, ReplayGain and loudness analysis, playlists, M3U8, artwork, folders
    Support/              Small shared extensions
  Sources/miniampctl      Developer CLI for the device and playback
project.yml               XcodeGen spec for the app target
scripts/                  Fixtures, the test library, benchmarks, and `make run`
```

## Known limitations

- Builds are signed ad hoc, with no team. Hardened runtime is on in `project.yml`, but Xcode only applies it when signing with a real identity, so set a team (and a Developer ID to distribute) to get a hardened, notarizable app.
- The minimum is macOS 15. Only macOS 27 has been run; on earlier systems the engine uses the older `AVAudioEngine` calls (`play()`, `connect`, `outputNode.audioUnit`) in place of their macOS 27 replacements.
- Tracks only join gaplessly when they share a format (sample rate and channel count). Otherwise, if the device stays at the same rate (a fixed-rate device such as a Bluetooth speaker, or a file it resamples), the next track starts on the running output after a few milliseconds of silence. If the device has to change rate, the switch takes about half a second.
- `AVAudioPlayerNode.playAudio()` waits on the main thread for the device's first I/O cycle. Normally that's milliseconds, but a device that never starts can block for up to about 5 seconds.
- Switching between bit-perfect and DSP mode while playing restarts the track where it was, which takes about half a second.
- In ReplayGain track mode, a gapless change to a track with a different gain switches the gain when the player sees the boundary, a few milliseconds into the new track.
- A sidecar `.lrc` is only found for songs inside a library folder: the sandbox doesn't let the app read files beside one opened with Open….
- Synced lyrics follow the audio as it's rendered, not as it's heard, so on a device with a lot of latency (Bluetooth) they come a little early. They don't measure it: set a delay in Settings › Lyrics (all songs), or nudge one song in the Lyrics pane.
- Looking up lyrics on LRCLIB is off by default. With it on, or when you search for a song from the Lyrics pane, the song's title, artist, album, and duration go to lrclib.net.
- A backup restores fully on the Mac it was made on. On another Mac the music folders need adding again: the sandbox's folder permissions are tied to the Mac that granted them. Cover thumbnails aren't in a backup; the next scan makes any that are missing.
- Romanized lyrics use the system's readings for Japanese and Chinese, and transliteration for other scripts, so Korean comes out letter by letter ("salanghae") rather than in Revised Romanization ("saranghae"). Translation uses Apple's on-device Translation; the first time, macOS asks to download the languages.
- The widget gets what's playing through an app group shared with the app. The group is named after the signing team (`$(TeamIdentifierPrefix)dev.miniamp`); with the ad-hoc signing used for now there's no team, so it's plain `dev.miniamp`, which recent macOS may not grant. If the widget stays on "Not Playing", set a development team in `project.yml`.
- Duplicates by sound compare fingerprints of each song's first two minutes, so a song that differs only later on (an extended version) still matches. Finding matches in a 10,000-song library takes a few seconds, each time the By Sound list loads. Songs shorter than a few seconds can't be fingerprinted.
- Crossfade works in DSP mode, between songs with the same sample rate and channel count; other pairs join as they would without it. It doesn't stretch tempos, so beats a few BPM apart drift a little over a long fade. A change to it applies from the next song scheduled, and a song you seek within its last seven seconds plays to its end without one.
- DSD as DoP is a setting, off by default, because a DAC can't be asked whether it takes DoP: one that doesn't plays it as noise. DoP is only used in bit-perfect mode on a device that runs at the DoP rate (176.4 kHz for DSD64) with 24-bit samples, and miniamp's volume doesn't apply. Everywhere else DSD is converted to 88.2 kHz PCM at DSD's own scale, so it plays about 6 dB quieter than a PCM master of the same recording. DST-compressed DFF files aren't supported.
- There are two volumes. The slider in the player bar is miniamp's own, as in Apple Music: below 100% it scales the samples, so playback isn't bit-perfect (the quality icon says so). The device's volume, under the output menu, changes the hardware level and keeps the samples intact.

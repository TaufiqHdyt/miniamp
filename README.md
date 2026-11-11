# miniamp

A native macOS music player for a local library. See [ROADMAP.md](ROADMAP.md).

## Development setup

Requirements: Apple silicon Mac, [Xcode](https://apps.apple.com/app/xcode/id497799835), [Homebrew](https://brew.sh).

```sh
sudo xcode-select -s /Applications/Xcode.app   # once, after installing Xcode
make bootstrap   # installs xcodegen, taglib, pkgconf; generates MiniAmp.xcodeproj
make open        # opens the project in Xcode
```

Other targets:

| Command        | What it does                                         |
|----------------|------------------------------------------------------|
| `make doctor`  | Checks that Xcode, TagLib, and XcodeGen are present  |
| `make project` | Regenerates `MiniAmp.xcodeproj` from `project.yml`   |
| `make build`   | Builds the app from the command line                 |
| `make run`     | Builds, launches the app, and streams its trace logs here (`VERBOSE=1` adds system messages) |
| `make test`    | Runs the `MiniAmpKit` tests (needs Xcode)            |
| `make fixtures`| Writes 10 s test tones in every format, plus a mono file, to `Fixtures/` |
| `make ctl ARGS="devices"` | Shows the output device's rates and physical formats |
| `make ctl ARGS="play <file>..."` | Plays files as a queue outside the sandbox and prints the signal path. Options: `--seconds N`, `--seek S`, `--device NAME`, `--hog`, `--repeat off\|all\|one`, `--shuffle`, `--dsp`, `--eq PRESET`, `--gain DB` |
| `make ctl ARGS="volume [0-1]"` | Reads or sets the default output device's own volume |
| `make ctl ARGS="library scan <folder>"` | Scans a folder into a scratch library (`$TMPDIR/miniampctl`, or `--db PATH`) and reports scan time and the longest main-actor stall. Also `library search <words>`, `library watch` (follows file changes live), `library stats`, and `library history` (the last 50 plays) |
| `make library-bench` | Generates a 10,000-track fake library in `/tmp/miniamp-library` (`TRACKS=N`), then scans it cold and again with nothing changed |
| `make bench`   | Measures CPU, energy impact, wakeups, and memory while playing silent files in each format (`SECS=N` per case, default 30). Quit miniamp first |

`MiniAmp.xcodeproj` is generated and not committed. Edit `project.yml` and run `make project` instead of changing build settings in Xcode.

## Layout

```
App/Sources/              SwiftUI app target (thin; UI only)
  App/                    Entry point, shared state, menus, settings, preferences
  Library/                Main window, sidebar, browsing, the track table, Get Info
  NowPlaying/             The now-playing inspector and its queue entries
  Player/                 Player bar, seek bar, volume, output picker, equalizer, Control Center
  Support/                Artwork, formatting, window visibility, hang logging
Packages/MiniAmpKit/      Everything testable: playback, library, database
  Sources/CTagLib         Links Homebrew TagLib through pkg-config
  Sources/TagLibBridge    C++ shim with a C API over TagLib
  Sources/CEBUR128        libebur128 (EBU R128 loudness), vendored unmodified
  Sources/MiniAmpKit/
    Audio/                Core Audio: devices, the hardware output, format selection
    Playback/             Player, queue, gapless scheduling, DSP mode and EQ, sleep timer, play history
    Library/              Database records, scanning, tag reading and writing, ReplayGain and loudness analysis, playlists, M3U8, artwork, folders
    Support/              Small shared extensions
  Sources/miniampctl      Developer CLI for the device and playback
project.yml               XcodeGen spec for the app target
scripts/                  Fixtures, the test library, benchmarks, and `make run`
```

## Known limitations

- TagLib is linked from Homebrew, so the app only runs on machines that have it installed. Hardened runtime is off for the same reason. To distribute the app, TagLib will need to be built from source and embedded.
- The minimum is macOS 27 because Homebrew's TagLib is built for it. Supporting older macOS means building TagLib from source with a lower target.
- Tracks only join gaplessly when they share a format (sample rate and channel count). Otherwise, if the device stays at the same rate (a fixed-rate device such as a Bluetooth speaker, or a file it resamples), the next track starts on the running output after a few milliseconds of silence. If the device has to change rate, the switch takes about half a second.
- `AVAudioPlayerNode.playAudio()` waits on the main thread for the device's first I/O cycle. Normally that's milliseconds, but a device that never starts can block for up to about 5 seconds.
- Switching between bit-perfect and DSP mode while playing restarts the track where it was, which takes about half a second.
- In ReplayGain track mode, a gapless change to a track with a different gain switches the gain when the player sees the boundary, a few milliseconds into the new track.

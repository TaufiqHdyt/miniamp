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
| `make fixtures`| Writes 10 s test tones in every format to `Fixtures/` |
| `make ctl ARGS="devices"` | Shows the output device's rates and physical formats |
| `make ctl ARGS="play <file>"` | Plays a file outside the sandbox and prints the signal path |

`MiniAmp.xcodeproj` is generated and not committed. Edit `project.yml` and run `make project` instead of changing build settings in Xcode.

## Layout

```
App/Sources/            SwiftUI app target (thin; UI only)
Packages/MiniAmpKit/    Everything testable: playback, library, database
  Sources/CTagLib       Links Homebrew TagLib through pkg-config
  Sources/TagLibBridge  C++ shim with a C API over TagLib
  Sources/MiniAmpKit    Swift code (GRDB, TagReader, ...)
  Sources/miniampctl    Developer CLI for the device and playback
project.yml             XcodeGen spec for the app target
scripts/                Fixture generation
```

## Known limitations

- TagLib is linked from Homebrew, so the app only runs on machines that have it installed. Hardened runtime is off for the same reason. To distribute the app, TagLib will need to be built from source and embedded.
- The minimum is macOS 27 because Homebrew's TagLib is built for it. Supporting older macOS means building TagLib from source with a lower target.
- Playback goes to the default output device only, and a device or rate change during playback isn't handled yet (M2).
- Files whose sample rate the device doesn't support play resampled by Core Audio; picking a better fallback rate is M2.
- Mono files go to the first output channel only, since the bit-perfect path has no mixer to upmix.

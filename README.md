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
| `make test`    | Runs the `MiniAmpKit` tests (needs Xcode)            |

`MiniAmp.xcodeproj` is generated and not committed. Edit `project.yml` and run `make project` instead of changing build settings in Xcode.

## Layout

```
App/Sources/            SwiftUI app target (thin; UI only)
Packages/MiniAmpKit/    Everything testable: playback, library, database
  Sources/CTagLib       Links Homebrew TagLib through pkg-config
  Sources/TagLibBridge  C++ shim with a C API over TagLib
  Sources/MiniAmpKit    Swift code (GRDB, TagReader, ...)
project.yml             XcodeGen spec for the app target
```

## Known limitations

- TagLib is linked from Homebrew, so the app only runs on machines that have it installed. Hardened runtime is off for the same reason. To distribute the app, TagLib will need to be built from source and embedded.
- Homebrew's TagLib is built for the host macOS. The deployment target of 15.0 only applies to code we compile ourselves.

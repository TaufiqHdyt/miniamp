.PHONY: bootstrap doctor project open build release clean run test fixtures ctl bench app-bench library-bench

bootstrap: doctor
	brew bundle --file=Brewfile
	xcodegen generate --quiet

doctor:
	@xcodebuild -version >/dev/null 2>&1 \
	  && echo "Xcode: $$(xcodebuild -version | head -1)" \
	  || echo "Xcode: NOT ACTIVE. Install Xcode, then: sudo xcode-select -s /Applications/Xcode.app"
	@command -v brew >/dev/null || { echo "Homebrew missing: https://brew.sh"; exit 1; }
	@command -v xcodegen >/dev/null && echo "XcodeGen: $$(xcodegen --version)" || echo "XcodeGen: missing (make bootstrap)"

project:
	xcodegen generate --quiet

open: project
	open MiniAmp.xcodeproj

build: project
	xcodebuild -project MiniAmp.xcodeproj -scheme miniamp -configuration Debug -destination "platform=macOS,arch=$(shell uname -m)" -derivedDataPath build -quiet build

# A Release build, zipped to build/release/miniamp-<version>-<arch>.zip, and a local
# v<version> tag if there isn't one. Nothing is pushed. ARCH=arm64 (default), x86_64 or universal.
ARCH ?= arm64
VERSION := $(shell awk '/MARKETING_VERSION:/ {print $$2; exit}' project.yml)
RELEASE_ZIP := build/release/miniamp-$(VERSION)-$(ARCH).zip
release: project
	@case "$(ARCH)" in arm64|x86_64|universal) ;; *) echo "ARCH must be arm64, x86_64 or universal"; exit 1;; esac
	xcodebuild -project MiniAmp.xcodeproj -scheme miniamp -configuration Release -destination "generic/platform=macOS" \
	  -derivedDataPath build -quiet ONLY_ACTIVE_ARCH=NO ARCHS="$(if $(filter universal,$(ARCH)),arm64 x86_64,$(ARCH))" build
	codesign --verify --deep --strict build/Build/Products/Release/miniamp.app
	@mkdir -p build/release
	ditto -c -k --keepParent build/Build/Products/Release/miniamp.app $(RELEASE_ZIP).tmp
	@mv -f $(RELEASE_ZIP).tmp $(RELEASE_ZIP)
	@git rev-parse -q --verify refs/tags/v$(VERSION) >/dev/null \
	  && echo "Tag v$(VERSION) exists; left as is" \
	  || { git tag -a v$(VERSION) -m "miniamp $(VERSION)" && echo "Tagged v$(VERSION) (local only)"; }
	@echo "$$(lipo -archs build/Build/Products/Release/miniamp.app/Contents/MacOS/miniamp): $(RELEASE_ZIP)"

# Removes the app's build and the Kit's (both rebuild from scratch, vendored C/C++ included).
clean:
	rm -rf build Packages/MiniAmpKit/.build

test:
	swift test --package-path Packages/MiniAmpKit

fixtures:
	scripts/make-fixtures.sh Fixtures 10

# Usage: make ctl ARGS="devices" | make ctl ARGS="play Fixtures/tone-96k-24.flac"
ctl:
	swift run --package-path Packages/MiniAmpKit -q miniampctl $(ARGS)

# Builds Debug, runs the app, and streams its trace logs here until it quits (Ctrl-C quits it).
# VERBOSE=1 adds system framework messages. Launch arguments go in ARGS,
# e.g. ARGS="-autoplay ~/Library/Containers/dev.miniamp.app/Data/tmp/tone-96k-24.flac"
run: build
	@VERBOSE=$(VERBOSE) scripts/run.sh $(ARGS)

bench:
	scripts/bench.sh $(or $(SECS),30)

# The app idle and playing, on a scratch library. CONFIG=Release for a Release build.
app-bench:
	scripts/app-bench.sh $(or $(SECS),30)

# Cold scan of a generated library, then a rescan with nothing changed. TRACKS=N (default 10000).
library-bench:
	scripts/make-library.py $(or $(TRACKS),10000) /tmp/miniamp-library
	swift build --package-path Packages/MiniAmpKit -c release --product miniampctl
	rm -rf /tmp/miniamp-library-db
	Packages/MiniAmpKit/.build/release/miniampctl library scan /tmp/miniamp-library --db /tmp/miniamp-library-db/library.sqlite
	Packages/MiniAmpKit/.build/release/miniampctl library scan /tmp/miniamp-library --db /tmp/miniamp-library-db/library.sqlite

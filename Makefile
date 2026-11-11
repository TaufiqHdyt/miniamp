.PHONY: bootstrap doctor project open build run test fixtures ctl bench library-bench

bootstrap: doctor
	brew bundle --file=Brewfile
	xcodegen generate --quiet

doctor:
	@xcodebuild -version >/dev/null 2>&1 \
	  && echo "Xcode: $$(xcodebuild -version | head -1)" \
	  || echo "Xcode: NOT ACTIVE. Install Xcode, then: sudo xcode-select -s /Applications/Xcode.app"
	@command -v brew >/dev/null || { echo "Homebrew missing: https://brew.sh"; exit 1; }
	@pkg-config --exists taglib 2>/dev/null && echo "TagLib: $$(pkg-config --modversion taglib)" || echo "TagLib: missing (make bootstrap)"
	@command -v xcodegen >/dev/null && echo "XcodeGen: $$(xcodegen --version)" || echo "XcodeGen: missing (make bootstrap)"

project:
	xcodegen generate --quiet

open: project
	open MiniAmp.xcodeproj

build: project
	xcodebuild -project MiniAmp.xcodeproj -scheme miniamp -configuration Debug -destination "platform=macOS,arch=$(shell uname -m)" -derivedDataPath build -quiet build

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

# Cold scan of a generated library, then a rescan with nothing changed. TRACKS=N (default 10000).
library-bench:
	scripts/make-library.py $(or $(TRACKS),10000) /tmp/miniamp-library
	swift build --package-path Packages/MiniAmpKit -c release --product miniampctl
	rm -rf /tmp/miniamp-library-db
	Packages/MiniAmpKit/.build/release/miniampctl library scan /tmp/miniamp-library --db /tmp/miniamp-library-db/library.sqlite
	Packages/MiniAmpKit/.build/release/miniampctl library scan /tmp/miniamp-library --db /tmp/miniamp-library-db/library.sqlite

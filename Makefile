.PHONY: bootstrap doctor project open build test

bootstrap: doctor
	brew bundle --file=Brewfile
	xcodegen generate

doctor:
	@xcodebuild -version >/dev/null 2>&1 \
	  && echo "Xcode: $$(xcodebuild -version | head -1)" \
	  || echo "Xcode: NOT ACTIVE. Install Xcode, then: sudo xcode-select -s /Applications/Xcode.app"
	@command -v brew >/dev/null || { echo "Homebrew missing: https://brew.sh"; exit 1; }
	@pkg-config --exists taglib 2>/dev/null && echo "TagLib: $$(pkg-config --modversion taglib)" || echo "TagLib: missing (make bootstrap)"
	@command -v xcodegen >/dev/null && echo "XcodeGen: $$(xcodegen --version)" || echo "XcodeGen: missing (make bootstrap)"

project:
	xcodegen generate

open: project
	open MiniAmp.xcodeproj

build: project
	xcodebuild -project MiniAmp.xcodeproj -scheme miniamp -configuration Debug -derivedDataPath build build

test:
	swift test --package-path Packages/MiniAmpKit

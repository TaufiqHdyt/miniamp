// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MiniAmpKit",
    platforms: [.macOS("27.0")], // matches Homebrew TagLib; lower once TagLib is built from source
    products: [
        .library(name: "MiniAmpKit", targets: ["MiniAmpKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // Links the Homebrew TagLib and supplies its compiler flags via pkg-config.
        .systemLibrary(
            name: "CTagLib",
            pkgConfig: "taglib",
            providers: [.brew(["taglib"])]
        ),
        // Small C++ shim exposing a C API, so Swift doesn't need C++ interop.
        .target(
            name: "TagLibBridge",
            dependencies: ["CTagLib"]
        ),
        // libebur128 (EBU R128 loudness), vendored unmodified; see Sources/CEBUR128/VERSION.
        .target(
            name: "CEBUR128",
            exclude: ["COPYING", "VERSION"],
            cSettings: [
                // It warns that it flushes denormals by hand on anything but SSE2, which is fine.
                .unsafeFlags(["-Wno-#warnings"]),
            ]
        ),
        .target(
            name: "MiniAmpKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "TagLibBridge",
                "CEBUR128",
            ]
        ),
        // Developer tool: inspect the output device and play files outside the sandbox.
        .executableTarget(
            name: "miniampctl",
            dependencies: ["MiniAmpKit", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "MiniAmpKitTests",
            dependencies: ["MiniAmpKit"],
            resources: [.copy("Fixtures")]
        ),
    ],
    cxxLanguageStandard: .cxx17
)

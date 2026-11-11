// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MiniAmpKit",
    platforms: [.macOS(.v15)],
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
        .target(
            name: "MiniAmpKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "TagLibBridge",
            ]
        ),
        .testTarget(
            name: "MiniAmpKitTests",
            dependencies: ["MiniAmpKit"]
        ),
    ],
    cxxLanguageStandard: .cxx17
)

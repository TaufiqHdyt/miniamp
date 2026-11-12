// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MiniAmpKit",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "MiniAmpKit", targets: ["MiniAmpKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // A C++ shim exposing a C API over TagLib, so Swift doesn't need C++ interop. TagLib
        // itself (and utfcpp, which it needs) is built from source here, as a static part of
        // this target; see Sources/TagLibBridge/VENDORED.txt.
        .target(
            name: "TagLibBridge",
            exclude: ["VENDORED.txt", "vendor/taglib/COPYING.LGPL", "vendor/taglib/COPYING.MPL", "vendor/utfcpp/LICENSE"],
            cxxSettings: [
                .headerSearchPath("vendor"),
                .headerSearchPath("vendor/taglib"),
                .headerSearchPath("vendor/taglib/ape"),
                .headerSearchPath("vendor/taglib/asf"),
                .headerSearchPath("vendor/taglib/dsdiff"),
                .headerSearchPath("vendor/taglib/dsf"),
                .headerSearchPath("vendor/taglib/flac"),
                .headerSearchPath("vendor/taglib/it"),
                .headerSearchPath("vendor/taglib/matroska"),
                .headerSearchPath("vendor/taglib/matroska/ebml"),
                .headerSearchPath("vendor/taglib/mod"),
                .headerSearchPath("vendor/taglib/mp4"),
                .headerSearchPath("vendor/taglib/mpc"),
                .headerSearchPath("vendor/taglib/mpeg"),
                .headerSearchPath("vendor/taglib/mpeg/id3v1"),
                .headerSearchPath("vendor/taglib/mpeg/id3v2"),
                .headerSearchPath("vendor/taglib/mpeg/id3v2/frames"),
                .headerSearchPath("vendor/taglib/ogg"),
                .headerSearchPath("vendor/taglib/ogg/flac"),
                .headerSearchPath("vendor/taglib/ogg/opus"),
                .headerSearchPath("vendor/taglib/ogg/speex"),
                .headerSearchPath("vendor/taglib/ogg/vorbis"),
                .headerSearchPath("vendor/taglib/riff"),
                .headerSearchPath("vendor/taglib/riff/aiff"),
                .headerSearchPath("vendor/taglib/riff/wav"),
                .headerSearchPath("vendor/taglib/s3m"),
                .headerSearchPath("vendor/taglib/shorten"),
                .headerSearchPath("vendor/taglib/toolkit"),
                .headerSearchPath("vendor/taglib/trueaudio"),
                .headerSearchPath("vendor/taglib/wavpack"),
                .headerSearchPath("vendor/taglib/xm"),
                .headerSearchPath("vendor/utfcpp"),
                .headerSearchPath("vendor/utfcpp/utf8"),
                .define("HAVE_CONFIG_H"),
                .define("TAGLIB_STATIC"),
            ],
            linkerSettings: [.linkedLibrary("z")]
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
        // Chromaprint (audio fingerprints, for duplicates), vendored; see Sources/CChromaprint/VENDORED.txt.
        .target(
            name: "CChromaprint",
            exclude: ["VENDORED.txt", "LICENSE.md"],
            cSettings: [
                .headerSearchPath("src"),
                .define("HAVE_CONFIG_H"),
                // FFmpeg's resampler narrows 64-bit values it has already bounded.
                .unsafeFlags(["-Wno-shorten-64-to-32"]),
            ],
            cxxSettings: [
                .headerSearchPath("src"),
                .define("HAVE_CONFIG_H"),
                .define("_USE_MATH_DEFINES"),
                .define("CHROMAPRINT_NODLL"),
            ],
            linkerSettings: [.linkedFramework("Accelerate")]
        ),
        .target(
            name: "MiniAmpKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "TagLibBridge",
                "CEBUR128",
                "CChromaprint",
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

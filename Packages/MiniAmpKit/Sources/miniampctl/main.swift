import CoreAudio
import Foundation
import MiniAmpKit

let usage = """
usage: miniampctl devices
       miniampctl play <file> [seconds]
"""

func printDevice() throws {
    let device = try AudioDevice.defaultOutput()
    print("Default output: \(device.name)")
    print("  nominal rate: \(FormatSelection.formatRate(try device.nominalSampleRate()))")
    let rates = try device.availableNominalSampleRates().map {
        $0.lowerBound == $0.upperBound
            ? FormatSelection.formatRate($0.lowerBound)
            : "\(FormatSelection.formatRate($0.lowerBound))–\(FormatSelection.formatRate($0.upperBound))"
    }
    print("  available rates: \(rates.joined(separator: ", "))")
    for stream in try device.outputStreams() {
        print("  stream \(stream) physical: \(FormatSelection.describe(try AudioDevice.physicalFormat(of: stream)))")
        for ranged in try AudioDevice.availablePhysicalFormats(of: stream) {
            print("    offers: \(FormatSelection.describe(ranged.mFormat))")
        }
    }
}

@MainActor
func play(_ path: String, seconds: Double?) async throws {
    let player = Player()
    try await player.play(URL(fileURLWithPath: path))
    if let path = player.signalPath { print(path.summary) }
    let deadline = seconds.map { Date().addingTimeInterval($0) }
    while player.state == .playing {
        if let deadline, Date() >= deadline { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    let device = try AudioDevice.defaultOutput()
    print("Device rate during playback: \(FormatSelection.formatRate(try device.nominalSampleRate()))")
    player.stop()
}

let args = CommandLine.arguments.dropFirst()
do {
    switch args.first {
    case "devices":
        try printDevice()
    case "play" where args.count >= 2:
        let rest = Array(args.dropFirst())
        try await play(rest[0], seconds: rest.count > 1 ? Double(rest[1]) : nil)
    default:
        print(usage)
        exit(64)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

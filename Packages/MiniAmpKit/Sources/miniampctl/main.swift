import CoreAudio
import Foundation
import MiniAmpKit

let usage = """
usage: miniampctl devices
       miniampctl volume [0...1]     read or set the default output device's volume
       miniampctl play [options] <file>...
options:
  --seconds N      stop after N seconds (default: play the whole queue)
  --seek S         seek to S seconds into the first track after it starts
  --device NAME    play to the output device whose name contains NAME
  --hog            take exclusive access (hog mode) while playing
  --repeat MODE    off | all | one
  --shuffle
       miniampctl library ...        scan, search, and watch a library (miniampctl library for help)
"""

func secondsString(_ d: Duration) -> String {
    String(format: "%.2f", d.seconds)
}

func formatRanges(_ ranges: [ClosedRange<Double>]) -> String {
    ranges.map {
        $0.lowerBound == $0.upperBound
            ? FormatSelection.formatRate($0.lowerBound)
            : "\(FormatSelection.formatRate($0.lowerBound))–\(FormatSelection.formatRate($0.upperBound))"
    }.joined(separator: ", ")
}

func printDevices() throws {
    let defaultID = (try? AudioDevice.defaultOutput().id) ?? 0
    for device in try AudioSystem.outputDevices() {
        let marker = device.id == defaultID ? " (default)" : ""
        print("\(device.name)\(marker)")
        print("  uid: \(device.uid)")
        print("  rate: \(FormatSelection.formatRate(try device.nominalSampleRate())); available: \(formatRanges(try device.availableNominalSampleRates()))")
        print("  channels: \(device.outputChannelCount)")
        print("  volume: \(device.volume().map { String(format: "%.3f", $0) } ?? "none (no device volume control)")")
        print("  hog mode: \(device.supportsHogMode ? "supported" : "not supported"), owner: \(device.hogModeOwner().map(String.init) ?? "none")")
        for stream in try device.outputStreams() {
            print("  stream \(stream): \(FormatSelection.describe(try AudioDevice.physicalFormat(of: stream)))")
        }
    }
}

@MainActor
func play(_ args: [String]) async throws {
    var files: [String] = []
    var seconds: Double?
    var seek: Double?
    var deviceName: String?
    var hog = false
    var repeatMode = PlayQueue<URL>.Repeat.off
    var shuffle = false
    var it = args.makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--seconds": seconds = it.next().flatMap(Double.init)
        case "--seek": seek = it.next().flatMap(Double.init)
        case "--device": deviceName = it.next()
        case "--hog": hog = true
        case "--repeat": repeatMode = it.next().flatMap(PlayQueue<URL>.Repeat.init(rawValue:)) ?? .off
        case "--shuffle": shuffle = true
        default: files.append(arg)
        }
    }
    guard !files.isEmpty else { print(usage); exit(64) }

    let player = Player()
    if let deviceName {
        guard let device = try AudioSystem.outputDevices().first(where: { $0.name.localizedCaseInsensitiveContains(deviceName) })
        else {
            FileHandle.standardError.write(Data("error: no output device matching '\(deviceName)'\n".utf8))
            exit(1)
        }
        player.preferredDeviceUID = device.uid
    }
    player.hogMode = hog
    player.repeatMode = repeatMode
    if shuffle { player.setShuffle(true) }

    let start = Date()
    func stamp() -> String { String(format: "%6.2fs", Date().timeIntervalSince(start)) }

    try await player.setQueue(files.map { URL(fileURLWithPath: $0) })
    var lastPath = player.signalPath
    var lastState = player.state
    print("\(stamp()) ▶ \(lastPath?.summary ?? "?")")
    if hog, let device = player.outputDevice {
        print("\(stamp())   hog owner: \(device.hogModeOwner().map(String.init) ?? "none") (this process: \(getpid()))")
    }

    if let seek {
        try await Task.sleep(for: .milliseconds(500))
        player.seek(to: .seconds(seek))
        try await Task.sleep(for: .milliseconds(300))
        print("\(stamp())   seek → \(seek)s; position now \(secondsString(player.position))s")
    }

    let deadline = seconds.map { start.addingTimeInterval($0) }
    while player.state != .stopped {
        if let deadline, Date() >= deadline { break }
        try await Task.sleep(for: .milliseconds(50))
        if player.signalPath != lastPath || player.state != lastState {
            lastPath = player.signalPath
            lastState = player.state
            print("\(stamp()) ▶ [\(player.state)] \(lastPath?.summary ?? "?")")
        }
    }
    let device = player.outputDevice
    player.stop()
    print("\(stamp()) ■ stopped; device \(device?.name ?? "?") at \(FormatSelection.formatRate((try? device?.nominalSampleRate()) ?? 0)), hog owner after stop: \(device?.hogModeOwner().map(String.init) ?? "none")")
}

// Line-buffered even into a pipe, so progress shows up as it happens.
setvbuf(stdout, nil, _IOLBF, 0)

let args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first {
    case "devices":
        try printDevices()
    case "play":
        try await play(Array(args.dropFirst()))
    case "library":
        try await libraryCommand(Array(args.dropFirst()))
    case "leaktest" where args.count >= 2:
        try await leakTest(args[1])
    case "volume":
        let device = try AudioDevice.defaultOutput()
        guard let before = device.volume() else {
            print("\(device.name) has no volume control")
            break
        }
        if let value = args.dropFirst().first.flatMap(Float.init) {
            try device.setVolume(value)
            print("\(device.name): \(before) → \(device.volume().map { "\($0)" } ?? "?")")
        } else {
            print("\(device.name): \(before)")
        }
    default:
        print(usage)
        exit(64)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

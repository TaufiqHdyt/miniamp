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
  --dsp            DSP mode instead of bit-perfect
  --eq PRESET      DSP mode with this EQ preset (Flat, Rock, Bass Boost, …)
  --gain DB        DSP mode, turned up or down by DB (as a preamp)
  --lyrics         print each line of the track's synced lyrics (.lrc or tags) as it's reached
  --lyrics-offset MS   with --lyrics, show them MS sooner (negative: later)
       miniampctl lyrics [--online] <file>   show a file's lyrics and where they came from
                                             (--online asks LRCLIB when the file has none)
       miniampctl fingerprint <file> [<other>]  a file's Chromaprint fingerprint, or how alike two files sound
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
    var dsp = false
    var preset: Equalizer.Preset?
    var showsLyrics = false
    var lyricsOffset = 0
    var gain: Float = 0
    var it = args.makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--seconds": seconds = it.next().flatMap(Double.init)
        case "--seek": seek = it.next().flatMap(Double.init)
        case "--device": deviceName = it.next()
        case "--hog": hog = true
        case "--repeat": repeatMode = it.next().flatMap(PlayQueue<URL>.Repeat.init(rawValue:)) ?? .off
        case "--shuffle": shuffle = true
        case "--dsp": dsp = true
        case "--lyrics": showsLyrics = true
        case "--lyrics-offset": lyricsOffset = it.next().flatMap(Int.init) ?? 0
        case "--eq":
            let name = it.next() ?? ""
            guard let match = Equalizer.Preset.all.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
                FileHandle.standardError.write(Data("error: no EQ preset '\(name)'; presets: \(Equalizer.Preset.all.map(\.name).joined(separator: ", "))\n".utf8))
                exit(64)
            }
            preset = match
            dsp = true
        case "--gain":
            gain = it.next().flatMap(Float.init) ?? 0
            dsp = true
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
    player.dspMode = dsp
    var eq = Equalizer(isEnabled: preset != nil || gain != 0)
    if let preset { eq.apply(preset) }
    eq.preamp += gain
    player.equalizer = eq
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

    // Lyrics follow the player the way the app's Lyrics pane does: a line prints when the
    // follower moves to it, with where the player really is at that moment.
    let follower = showsLyrics ? LyricsFollower(player: player) : nil
    follower?.offset = .milliseconds(lyricsOffset)
    var lyricsURL: URL?
    var lastLine: Int?
    func followLyrics() async {
        guard let follower else { return }
        if player.queue.current != lyricsURL, let url = player.queue.current {
            lyricsURL = url
            let found = await LocalLyrics.find(for: url)
            follower.lyrics = found?.lyrics
            lastLine = nil
            print("\(stamp())   lyrics: \(found.map { "\($0.lyrics.lines.count) lines, \($0.lyrics.isSynced ? "synced" : "plain")" } ?? "none")")
        }
        if let line = follower.position.line, line != lastLine, let lyrics = follower.lyrics {
            lastLine = line
            let due = lyrics.lines[line].time ?? .zero
            print("\(stamp())   ♪ [\(secondsString(due))] \(lyrics.lines[line].text)  (player at \(secondsString(player.exactTime)))")
        }
    }
    await followLyrics()

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
        await followLyrics()
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

@MainActor
func showLyrics(_ args: [String]) async throws {
    let online = args.contains("--online")
    guard let path = args.first(where: { $0 != "--online" }) else { print(usage); exit(64) }
    let finder = LyricsFinder(database: nil, client: online ? LRCLIB(userAgent: "miniampctl") : nil)
    switch try await finder.find(for: URL(fileURLWithPath: path), online: online ? .refresh : .off) {
    case .notFound(let searched):
        print(searched ? "no lyrics (LRCLIB has none either)" : "no lyrics")
    case .found(let found):
        let source = switch found.source {
        case .sidecar(let url): url.lastPathComponent
        case .embedded: "the file's tags"
        case .lrclib(let id): "LRCLIB #\(id)"
        }
        let lyrics = found.lyrics
        print("from \(source): \(lyrics.isInstrumental ? "instrumental" : "\(lyrics.lines.count) lines"), "
              + "\(lyrics.isSynced ? lyrics.hasWordTiming ? "synced by word" : "synced" : "plain")")
        for (key, value) in lyrics.metadata.sorted(by: { $0.key < $1.key }) { print("  [\(key)] \(value)") }
        for line in lyrics.lines {
            print(line.time.map { "  \(secondsString($0).leftPad(7))  " } ?? "  ", terminator: "")
            print(line.text.isEmpty ? "♪" : line.text)
        }
    }
}

extension String {
    func leftPad(_ width: Int) -> String { String(repeating: " ", count: max(0, width - count)) + self }
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
    case "fingerprint" where args.count == 2 || args.count == 3:
        let start = ContinuousClock.now
        let a = try Fingerprints.compute(URL(fileURLWithPath: args[1]))
        print("\(args[1]): \(a.count) values in \((ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds])))")
        if a.isEmpty { print("too short to fingerprint (it takes a few seconds of audio)") }
        if args.count == 3 {
            let b = try Fingerprints.compute(URL(fileURLWithPath: args[2]))
            let score = Fingerprints.similarity(a, b)
            print(String(format: "similarity %.3f: %@", score, score >= Fingerprints.matchThreshold ? "the same recording" : "different"))
        }
    case "lyrics" where args.count >= 2:
        try await showLyrics(Array(args.dropFirst()))
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

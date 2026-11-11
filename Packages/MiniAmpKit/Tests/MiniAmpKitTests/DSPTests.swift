import AVFoundation
import Foundation
import GRDB
import Testing
@testable import MiniAmpKit

/// Issues #30 and #31: switching between the bit-perfect and DSP graphs, and the EQ.
///
/// Offline manual rendering, so no audio hardware is involved.
@MainActor
@Suite struct DSPGraphTests {
    /// The milestone's "done when": bit-perfect mode leaves nothing but the player and the output.
    @Test func bitPerfectModeRemovesTheDSPNode() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ(numberOfBands: Equalizer.frequencies.count)
        engine.attach(node)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)

        try Player.connect(node, through: eq, detaching: eq, in: engine, format: format)
        #expect(eq.engine === engine)
        #expect(engine.inputConnectionPoint(for: engine.outputNode, inputBus: 0)?.node === eq)
        #expect(engine.inputConnectionPoint(for: eq, inputBus: 0)?.node === node)

        try Player.connect(node, through: nil, detaching: eq, in: engine, format: format)
        #expect(eq.engine == nil)
        #expect(engine.inputConnectionPoint(for: engine.outputNode, inputBus: 0)?.node === node)
        #expect(Set(engine.attachedNodes.map(ObjectIdentifier.init)) ==
                Set([node, engine.outputNode].map { ObjectIdentifier($0) }))

        // And back, as switching modes again would.
        try Player.connect(node, through: eq, detaching: eq, in: engine, format: format)
        #expect(engine.inputConnectionPoint(for: engine.outputNode, inputBus: 0)?.node === eq)
    }

    @Test(arguments: [0.0, -6.0, 3.5])
    func dspGainScalesTheSamples(_ gain: Double) throws {
        let url = try SineFile.write(amplitude: 0.25, seconds: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        var settings = Equalizer()
        settings.isEnabled = true // all bands flat: only the gain acts
        let eq = AVAudioUnitEQ(numberOfBands: Equalizer.frequencies.count)
        settings.configure(eq)
        eq.globalGain = Float(gain)

        let (input, output) = try render(url, through: eq)
        let expected = Float(pow(10, gain / 20))
        // Skip the start, where the filters settle.
        let ratios = (4800..<Int(input.frameLength)).compactMap { i -> Float? in
            let x = input.floatChannelData![0][i]
            return abs(x) > 0.05 ? output.floatChannelData![0][i] / x : nil
        }
        #expect(!ratios.isEmpty)
        #expect(ratios.allSatisfy { abs($0 - expected) < 0.001 }, "expected ×\(expected), got \(ratios.min()!)…\(ratios.max()!)")
    }

    @Test func eqBandChangesItsFrequencyOnly() throws {
        // +6 dB at 1 kHz: a 1 kHz tone comes out about twice as loud.
        let url = try SineFile.write(amplitude: 0.1, frequency: 1000, seconds: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        var settings = Equalizer(isEnabled: true)
        settings.gains[5] = 6
        let eq = AVAudioUnitEQ(numberOfBands: Equalizer.frequencies.count)
        settings.configure(eq)
        #expect(eq.bands[0].filterType == .lowShelf)
        #expect(eq.bands[9].filterType == .highShelf)
        #expect(eq.bands.enumerated().allSatisfy { $0.element.bypass == ($0.offset != 5) })

        let (input, output) = try render(url, through: eq)
        let gain = 20 * log10(peak(output, from: 12_000) / peak(input, from: 12_000))
        #expect(abs(gain - 6) < 0.5, "got \(gain) dB")
    }

    private func render(_ url: URL, through eq: AVAudioUnitEQ) throws -> (AVAudioPCMBuffer, AVAudioPCMBuffer) {
        let input = try TestAudio.decodeAll(url)
        let file = try AVAudioFile(forReading: url)
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        try engine.enableManualRenderingMode(.offline, format: file.processingFormat, maximumFrameCount: 4096)
        try Player.connect(node, through: eq, detaching: eq, in: engine, format: file.processingFormat)
        node.scheduleFile(file, at: nil)
        try engine.start()
        try node.playAudio()
        defer { engine.stop() }
        let output = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: input.frameLength)!
        let chunk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        while output.frameLength < input.frameLength {
            #expect(try engine.renderOffline(min(4096, input.frameLength - output.frameLength), to: chunk) == .success)
            for c in 0..<Int(chunk.format.channelCount) {
                (output.floatChannelData![c] + Int(output.frameLength)).update(from: chunk.floatChannelData![c], count: Int(chunk.frameLength))
            }
            output.frameLength += chunk.frameLength
        }
        return (input, output)
    }

    private func peak(_ buffer: AVAudioPCMBuffer, from start: Int) -> Double {
        Double((start..<Int(buffer.frameLength)).map { abs(buffer.floatChannelData![0][$0]) }.max() ?? 0)
    }
}

/// Issues #31 and #32: EQ settings, and how ReplayGain picks a gain.
@Suite struct DSPSettingsTests {
    @Test func replayGainModes() {
        let rg = ReplayGain(trackGain: -7, trackPeak: 0.9, albumGain: -5, albumPeak: 0.99)
        #expect(rg.gain(.off) == 0)
        #expect(rg.gain(.track) == -7)
        #expect(rg.gain(.album) == -5)
        // No album gain: album mode uses the track's.
        #expect(ReplayGain(trackGain: -7).gain(.album) == -7)
        // A preamp that would push the peak past full scale is held back.
        // (A 0.9 peak leaves 0.92 dB of headroom; -7 + 9 = +2 would go past it.)
        #expect(abs(rg.gain(.track, preamp: 9) - (-20 * log10(0.9))) < 1e-9)
        #expect(rg.gain(.track, preamp: 9, preventClipping: false) == 2)
        #expect(rg.gain(.track, preamp: 1) == -6)
    }

    @Test func equalizerPresetsAndLimits() {
        var eq = Equalizer(gains: [20, -20, 1])
        #expect(eq.gains == [12, -12, 1, 0, 0, 0, 0, 0, 0, 0])
        #expect(eq.preset == nil)
        let rock = Equalizer.Preset.all.first { $0.name == "Rock" }!
        eq.apply(rock)
        #expect(eq.preset == rock)
        #expect(!eq.isShaping) // still off
        eq.isEnabled = true
        #expect(eq.isShaping)
        #expect(Equalizer.Preset.all.allSatisfy { $0.gains.count == Equalizer.frequencies.count })
        // Each preset's preamp leaves room for its biggest boost.
        #expect(Equalizer.Preset.all.allSatisfy { $0.preamp + ($0.gains.max() ?? 0) <= 0 })
        let data = try! JSONEncoder().encode(eq)
        #expect(try! JSONDecoder().decode(Equalizer.self, from: data) == eq)
    }

    @Test func processingDescription() {
        let p = SignalPath.Processing(equalizer: "Rock", replayGain: .album, trackHasReplayGain: true, gain: -8.25)
        #expect(p.description == "EQ Rock, ReplayGain (album), -8.2 dB")
        let none = SignalPath.Processing(equalizer: nil, replayGain: .off, trackHasReplayGain: false, gain: 0)
        #expect(none.description == "+0.0 dB")
        var path = SignalPath(codec: "FLAC", fileSampleRate: 44_100, fileBitDepth: 16, fileChannels: 2,
                              engineSampleRate: 44_100, deviceName: "D", deviceSampleRate: 44_100,
                              devicePhysicalFormat: "24-bit integer", devicePhysicalBits: 24)
        #expect(path.verdict == .bitPerfect)
        path.processing = none
        #expect(path.verdict == .processed)
    }
}

/// Issues #32 and #33: ReplayGain from tags, and measuring it with libebur128.
@Suite(.serialized) struct ReplayGainTests {
    /// EBU Tech 3341, case 1: a stereo 1 kHz sine at -23 dBFS measures -23 LUFS.
    @Test func measuresTheReferenceTone() throws {
        let url = try SineFile.write(amplitude: pow(10, -23.0 / 20), frequency: 1000, seconds: 5)
        defer { try? FileManager.default.removeItem(at: url) }
        let meter = try LoudnessMeter.measure(url)
        let loudness = try #require(meter.loudness)
        #expect(abs(loudness - -23) < 0.1, "measured \(loudness) LUFS")
        #expect(abs(meter.peak - pow(10, -23.0 / 20)) < 0.001)
    }

    @Test func albumLoudnessIsOfAllTheAudioTogether() throws {
        let loud = try SineFile.write(amplitude: 0.5, seconds: 3)
        let quiet = try SineFile.write(amplitude: 0.125, seconds: 3)
        let silent = try SineFile.write(amplitude: 0, seconds: 1)
        defer { [loud, quiet, silent].forEach { try? FileManager.default.removeItem(at: $0) } }
        let tracks = [loud, quiet, silent].enumerated().map { i, url in
            Track(id: Int64(i + 1), folderId: 1, path: url.path, fileSize: 1, modifiedAt: 0, title: "\(i)", albumId: 7,
                  durationMs: 1000, sampleRate: 48_000, channels: 2, bitrateKbps: 0, codec: "WAV", addedAt: Date())
        }
        let gains = LoudnessScanner.measure(tracks)
        let a = try #require(gains[0]), b = try #require(gains[1])
        #expect(gains[2] == nil) // silence has no loudness
        // A quarter of the amplitude is 12 dB quieter, so it gets 12 dB more gain.
        #expect(abs((b.trackGain - a.trackGain) - 20 * log10(4)) < 0.05)
        let album = try #require(a.albumGain)
        #expect(a.albumGain == b.albumGain)
        #expect(album < b.trackGain && album > a.trackGain)
        #expect(abs((a.albumPeak ?? 0) - 0.5) < 0.001)
        #expect(abs((b.trackPeak ?? 0) - 0.125) < 0.001)
    }

    @Test func readsReplayGainTagsAndPrefersThemToAScan() async throws {
        let db = try AppDatabase.inMemory()
        let folder = try TestFolder()
        let audio = try Data(contentsOf: TestAudio.mp3Fixture)
        try folder.write(ID3.tag([("TIT2", "Tagged"), ("TXXX", "REPLAYGAIN_TRACK_GAIN\u{0}\u{FEFF}-6.50 dB"),
                                  ("TXXX", "REPLAYGAIN_TRACK_PEAK\u{0}\u{FEFF}0.912"),
                                  ("TXXX", "REPLAYGAIN_ALBUM_GAIN\u{0}\u{FEFF}+1.25 dB")]) + audio, to: "a.mp3")
        let tags = try #require(TagReader.read(folder.url.appendingPathComponent("a.mp3")))
        #expect(tags.replayGain == ReplayGain(trackGain: -6.5, trackPeak: 0.912, albumGain: 1.25, albumPeak: nil))

        try folder.mp3("b.mp3", title: "Untagged")
        let library = await Library(database: db, artwork: nil)
        await library.open()
        try await library.addFolder(folder.url)
        await library.waitForScans()
        let a = folder.canonical("a.mp3"), b = folder.canonical("b.mp3")
        #expect(try await db.writer.read { try ReplayGains.lookup(path: a, $0) }?.trackGain == -6.5)
        #expect(try await db.writer.read { try ReplayGains.lookup(path: b, $0) } == nil)
        #expect(try await db.writer.read { try ReplayGains.unmeasuredTrackIds($0) }.count == 1)

        // Analysis fills in the untagged track; the tagged one keeps its tags' values.
        await library.analyzeLoudness(trackIds: try await db.writer.read { try Track.fetchAll($0) }.compactMap(\.id))
        await library.waitForLoudnessAnalysis()
        #expect(try await db.writer.read { try ReplayGains.lookup(path: a, $0) }?.trackGain == -6.5)
        let measured = try #require(try await db.writer.read { try ReplayGains.lookup(path: b, $0) })
        #expect(measured.trackGain.isFinite && measured.trackGain != -6.5)
        #expect(try await db.writer.read { try ReplayGains.unmeasuredTrackIds($0) }.isEmpty)
        #expect(await library.lastError == nil)
    }
}

/// A float WAV of a sine on every channel.
enum SineFile {
    static func write(amplitude: Double, frequency: Double = 1000, sampleRate: Double = 48_000,
                      channels: AVAudioChannelCount = 2, seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("miniamp-sine-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<Int(channels) {
            for i in 0..<Int(frames) {
                buffer.floatChannelData![c][i] = Float(amplitude * sin(2 * .pi * frequency * Double(i) / sampleRate))
            }
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
                                       AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 32,
                                       AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        return url
    }
}

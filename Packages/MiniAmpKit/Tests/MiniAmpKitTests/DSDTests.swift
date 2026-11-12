import AVFoundation
import Foundation
import Testing
@testable import MiniAmpKit

/// Issue #43: DSF and DSDIFF files play, as DoP for DACs that take it or converted to PCM.
@Suite struct DSDTests {
    // MARK: Writing test files

    /// Writes a DSF file with `bytes` per channel (MSB-first), stored LSB-first as DSF usually is.
    static func writeDSF(_ bytes: [[UInt8]], rate: Int = 2_822_400, lsbFirst: Bool = true) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("miniamp-test-\(UUID().uuidString).dsf")
        let block = 4096, channels = bytes.count, perChannel = bytes[0].count
        let blocks = (perChannel + block - 1) / block
        var body = Data()
        for b in 0..<blocks {
            for ch in 0..<channels {
                for i in 0..<block {
                    let index = b * block + i
                    let byte = index < perChannel ? bytes[ch][index] : 0
                    body.append(lsbFirst ? DSDFile.reversed[Int(byte)] : byte)
                }
            }
        }
        var d = Data()
        d.append(contentsOf: Array("DSD ".utf8)); d.le(UInt64(28)); d.le(UInt64(28 + 52 + 12 + body.count)); d.le(UInt64(0))
        d.append(contentsOf: Array("fmt ".utf8)); d.le(UInt64(52)); d.le(UInt32(1)); d.le(UInt32(0))
        d.le(UInt32(channels == 1 ? 1 : 2)); d.le(UInt32(channels)); d.le(UInt32(rate)); d.le(UInt32(lsbFirst ? 1 : 8))
        d.le(UInt64(perChannel * 8)); d.le(UInt32(block)); d.le(UInt32(0))
        d.append(contentsOf: Array("data".utf8)); d.le(UInt64(12 + body.count))
        d.append(body)
        try d.write(to: url)
        return url
    }

    /// Writes a DSDIFF file with `bytes` per channel, interleaved a byte at a time.
    static func writeDFF(_ bytes: [[UInt8]], rate: Int = 2_822_400, compression: String = "DSD ") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("miniamp-test-\(UUID().uuidString).dff")
        let channels = bytes.count
        var sound = Data()
        for i in 0..<bytes[0].count { for ch in 0..<channels { sound.append(bytes[ch][i]) } }
        var prop = Data(Array("SND ".utf8))
        prop.append(contentsOf: Array("FS  ".utf8)); prop.be(UInt64(4)); prop.be(UInt32(rate))
        prop.append(contentsOf: Array("CHNL".utf8)); prop.be(UInt64(2 + 4 * channels)); prop.be(UInt16(channels))
        for ch in 0..<channels { prop.append(contentsOf: Array((ch == 0 ? "SLFT" : "SRGT").utf8)) }
        prop.append(contentsOf: Array("CMPR".utf8)); prop.be(UInt64(4 + 1 + 15)); prop.append(contentsOf: Array(compression.utf8))
        prop.append(14); prop.append(contentsOf: Array("not compressed".utf8)); prop.append(0)
        var form = Data(Array("DSD ".utf8))
        form.append(contentsOf: Array("FVER".utf8)); form.be(UInt64(4)); form.be(UInt32(0x0105_0000))
        form.append(contentsOf: Array("PROP".utf8)); form.be(UInt64(prop.count)); form.append(prop)
        if prop.count & 1 == 1 { form.append(0) }
        form.append(contentsOf: Array("DSD ".utf8)); form.be(UInt64(sound.count)); form.append(sound)
        var d = Data(Array("FRM8".utf8)); d.be(UInt64(form.count)); d.append(form)
        try d.write(to: url)
        return url
    }

    /// A second-order sigma-delta modulator: `signal` (one value per DSD bit) as MSB-first bytes.
    static func modulate(_ signal: (Int) -> Double, bits: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: bits / 8)
        var i1 = 0.0, i2 = 0.0, y = 0.0
        for n in 0..<bits {
            i1 += signal(n) - y
            i2 += i1 - y
            y = i2 >= 0 ? 1 : -1
            if y > 0 { out[n / 8] |= UInt8(0x80) >> UInt8(n % 8) }
        }
        return out
    }

    static func randomBytes(_ count: Int) -> [UInt8] { (0..<count).map { _ in UInt8.random(in: 0...255) } }

    // MARK: Files

    @Test func readsDSFAndDSDIFF() throws {
        let bytes = [Self.randomBytes(10_000), Self.randomBytes(10_000)]
        for url in [try Self.writeDSF(bytes), try Self.writeDSF(bytes, lsbFirst: false), try Self.writeDFF(bytes)] {
            defer { try? FileManager.default.removeItem(at: url) }
            let file = try DSDFile(url: url)
            #expect(file.channels == 2)
            #expect(file.sampleRate == 2_822_400)
            #expect(file.name == "DSD64")
            #expect(file.byteCount == 10_000)
            // Across DSF's 4096-byte blocks, and past the end into silence.
            for ch in 0..<2 {
                var out = [UInt8](repeating: 0, count: 6_100)
                file.copyBytes(channel: ch, from: 4_000, count: 6_100, into: &out)
                #expect(Array(out[..<6_000]) == Array(bytes[ch][4_000...]), "\(url.pathExtension) channel \(ch)")
                #expect(out[6_000...].allSatisfy { $0 == DSDFile.silence })
            }
        }
    }

    @Test func refusesCompressedDSDIFF() throws {
        let url = try Self.writeDFF([Self.randomBytes(64)], compression: "DST ")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: DSDFile.FileError.self) { try DSDFile(url: url) }
    }

    @Test func tagsReportTheDSDRate() throws {
        let url = try Self.writeDSF([Self.randomBytes(8_192), Self.randomBytes(8_192)])
        defer { try? FileManager.default.removeItem(at: url) }
        let tags = try #require(TagReader.read(url))
        #expect(tags.codec == "DSD64")
        #expect(tags.sampleRate == 2_822_400)
        #expect(tags.bitsPerSample == 1)
    }

    // MARK: DoP

    @Test func dopPacksSixteenBitsUnderAlternatingMarkers() throws {
        let bytes = [Self.randomBytes(9_000), Self.randomBytes(9_000)]
        let url = try Self.writeDSF(bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = try DSDDecoder(url: url, mode: .dop)
        #expect(decoder.processingFormat.sampleRate == 176_400)
        #expect(decoder.length == 4_500)

        // From an odd frame, across a block boundary (byte 4096 is frame 2048).
        decoder.framePosition = 2_001
        let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 100)!
        try decoder.read(into: buffer)
        #expect(buffer.frameLength == 100)
        for ch in 0..<2 {
            for i in 0..<100 {
                let frame = 2_001 + i
                let value = Int32(buffer.floatChannelData![ch][i] * 8_388_608)
                let bits = UInt32(bitPattern: value) & 0xFF_FFFF
                #expect(bits >> 16 == (frame % 2 == 0 ? 0x05 : 0xFA))
                #expect(UInt8((bits >> 8) & 0xFF) == bytes[ch][2 * frame])
                #expect(UInt8(bits & 0xFF) == bytes[ch][2 * frame + 1])
            }
        }
    }

    // MARK: PCM

    @Test func pcmConversionPlaysTheSignal() throws {
        let rate = 2_822_400, seconds = 0.25
        let sine = { (n: Int) in 0.5 * sin(2 * .pi * 1_000 * Double(n) / Double(rate)) }
        let url = try Self.writeDSF([Self.modulate(sine, bits: Int(Double(rate) * seconds))])
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DSDDecoder(url: url, mode: .pcm)
        #expect(decoder.processingFormat.sampleRate == 88_200)
        let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: AVAudioFrameCount(decoder.length))!
        try decoder.read(into: buffer)
        let out = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))

        // Away from the edges: the best-fitting 1 kHz sine, and what's left over.
        let range = 1_000..<(out.count - 1_000)
        var ss = 0.0, sc = 0.0
        for i in range {
            let t = 2 * .pi * 1_000 * Double(i) / 88_200
            ss += Double(out[i]) * sin(t)
            sc += Double(out[i]) * cos(t)
        }
        let a = 2 * ss / Double(range.count), b = 2 * sc / Double(range.count)
        let amplitude = (a * a + b * b).squareRoot()
        var residual = 0.0
        for i in range {
            let t = 2 * .pi * 1_000 * Double(i) / 88_200
            let e = Double(out[i]) - a * sin(t) - b * cos(t)
            residual += e * e
        }
        let noise = (residual / Double(range.count)).squareRoot()
        #expect(abs(amplitude - 0.5) < 0.01, "amplitude \(amplitude)")
        // In phase: the filter is centred on each output, so it adds no delay.
        #expect(abs(b) < 0.01, "phase error \(atan2(b, a))")
        #expect(20 * log10(noise / (amplitude / 2.squareRoot())) < -50, "noise \(noise)")
    }

    @Test func pcmConversionOfSilenceIsSilent() throws {
        let url = try Self.writeDSF([[UInt8](repeating: DSDFile.silence, count: 20_000)])
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = try DSDDecoder(url: url, mode: .pcm)
        let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: AVAudioFrameCount(decoder.length))!
        try decoder.read(into: buffer)
        let peak = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)).map(abs).max() ?? 1
        #expect(peak < 0.01)
    }

    @Test func analysisReadsDSDAsPCM() throws {
        let rate = 2_822_400
        let url = try Self.writeDSF([Self.modulate({ 0.25 * sin(2 * .pi * 440 * Double($0) / Double(rate)) }, bits: rate)])
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try PCMReader.open(url)
        #expect(reader.processingFormat.sampleRate == 88_200)
        #expect(reader.length == 88_200 / 8 * 8)
    }

    // MARK: Playback

    /// Two DSD tracks streamed through the scheduler's pump, rendered offline: DoP frames come
    /// out exactly, back to back, with the markers alternating straight across the join.
    @MainActor @Test func dsdTracksPlayGaplesslyAsDoP() throws {
        let a = [Self.randomBytes(30_001), Self.randomBytes(30_001)]
        let b = [Self.randomBytes(20_000), Self.randomBytes(20_000)]
        let urlA = try Self.writeDSF(a), urlB = try Self.writeDFF(b)
        defer { [urlA, urlB].forEach { try? FileManager.default.removeItem(at: $0) } }
        let fileA = try TrackFile(dsd: DSDFile(url: urlA), mode: .dop)
        let fileB = try TrackFile(dsd: DSDFile(url: urlB), mode: .dop)
        #expect(fileB.canFollow(fileA))

        let rig = try GaplessTests.Rig(format: fileA.processingFormat)
        rig.scheduler.append(fileA, token: 0)
        rig.scheduler.append(fileB, token: 1)
        try rig.start()
        defer { rig.engine.stop() }

        let total = Int(fileA.length + fileB.length)
        let out = try rig.render(total)
        for ch in 0..<2 {
            let bytes = Array(a[ch][..<30_000]) + b[ch]
            let mismatch = (0..<total).first { i in
                let bits = UInt32(bitPattern: Int32(out[ch][i] * 8_388_608)) & 0xFF_FFFF
                let expected = UInt32(i % 2 == 0 ? 0x05 : 0xFA) << 16 | UInt32(bytes[2 * i]) << 8 | UInt32(bytes[2 * i + 1])
                return bits != expected
            }
            #expect(mismatch == nil, "channel \(ch) differs at frame \(mismatch ?? -1) (join at \(fileA.length))")
        }
    }

    @Test func dsdDoesNotFollowPCM() throws {
        let dsdURL = try Self.writeDSF([Self.randomBytes(1_000), Self.randomBytes(1_000)])
        let pcmURL = try TestAudio.write(TestAudio.Spec(formatID: kAudioFormatFLAC, fileExtension: "flac",
                                                        sampleRate: 88_200, bits: 24), seconds: 0.1)
        defer { [dsdURL, pcmURL].forEach { try? FileManager.default.removeItem(at: $0) } }
        let dsd = try TrackFile.open(dsdURL)
        let pcm = try TrackFile.open(pcmURL)
        #expect(dsd.processingFormat == pcm.processingFormat)
        #expect(!dsd.canFollow(pcm))
        #expect(!pcm.canFollow(dsd))
    }

    @Test func signalPathDescribesDSD() {
        var path = SignalPath(codec: "DSD64", fileSampleRate: 2_822_400, fileBitDepth: 1, fileChannels: 2,
                              engineSampleRate: 176_400, deviceName: "DAC", deviceSampleRate: 176_400,
                              devicePhysicalFormat: "24-bit integer")
        path.dsd = .init(name: "DSD64", isDoP: true)
        path.appVolume = 0.5
        #expect(path.verdict == .dsdOverPCM)
        #expect(!path.isResampled)
        #expect(path.fileDescription == "DSD64 (2.8 MHz)")

        path.dsd = .init(name: "DSD64", isDoP: false)
        path.appVolume = 1
        path.engineSampleRate = 88_200
        path.deviceSampleRate = 88_200
        #expect(path.verdict == .dsdConverted(to: 88_200))
        #expect(!path.isResampled)
    }
}

extension Data {
    fileprivate mutating func le<T: FixedWidthInteger>(_ value: T) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    fileprivate mutating func be<T: FixedWidthInteger>(_ value: T) { Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) } }
}

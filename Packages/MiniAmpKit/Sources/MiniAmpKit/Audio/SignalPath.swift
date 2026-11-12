import AVFoundation
import CoreAudio

/// What the file is, what the engine feeds the output unit, and what the device is actually doing.
public struct SignalPath: Sendable, Equatable {
    public var codec: String
    public var fileSampleRate: Double
    /// nil for lossy formats with no fixed bit depth.
    public var fileBitDepth: Int?
    public var fileChannels: Int
    /// Sample rate of the format the player node hands to the output node.
    public var engineSampleRate: Double
    public var deviceName: String
    public var deviceSampleRate: Double
    public var devicePhysicalFormat: String
    /// Bits per sample the device takes, and whether they're float. Nil when it couldn't be read.
    public var devicePhysicalBits: Int?
    public var devicePhysicalIsFloat: Bool
    /// Other apps can't play to the device while this holds it.
    public var isExclusive: Bool
    /// What DSP mode does to the samples; nil in bit-perfect mode, where nothing is in the way.
    public var processing: Processing?
    /// The app volume, 0...1 (see `Player.appVolume`); below 1 the samples are scaled.
    /// DoP ignores it.
    public var appVolume: Float = 1
    /// Set for a DSD file: how it's sent.
    public var dsd: DSD?

    public struct DSD: Sendable, Equatable {
        /// "DSD64", "DSD128"…
        public var name: String
        /// Sent to the DAC as DoP, bit for bit, rather than converted to PCM.
        public var isDoP: Bool

        public init(name: String, isDoP: Bool) {
            self.name = name
            self.isDoP = isDoP
        }
    }

    /// DSP mode's stage between the player and the output.
    public struct Processing: Sendable, Equatable {
        /// The EQ preset ("Custom" if none matches), or nil when the EQ is off or flat.
        public var equalizer: String?
        public var replayGain: ReplayGain.Mode
        /// Whether the track has ReplayGain values (from its tags or an analysis).
        public var trackHasReplayGain: Bool
        /// Everything the samples are turned up or down by, dB: ReplayGain and the preamps.
        public var gain: Double
        /// Seconds tracks crossfade over; nil when they don't.
        public var crossfade: Double?

        public init(equalizer: String?, replayGain: ReplayGain.Mode, trackHasReplayGain: Bool, gain: Double,
                    crossfade: Double? = nil) {
            self.equalizer = equalizer
            self.replayGain = replayGain
            self.trackHasReplayGain = trackHasReplayGain
            self.gain = gain
            self.crossfade = crossfade
        }

        public var description: String {
            var parts: [String] = []
            if let equalizer { parts.append("EQ \(equalizer)") }
            switch replayGain {
            case .off: break
            case .track, .album:
                parts.append(trackHasReplayGain ? "ReplayGain (\(replayGain.rawValue))" : "ReplayGain (no values for this track)")
            }
            if gain != 0 || parts.isEmpty { parts.append(String(format: "%+.1f dB", gain)) }
            if let crossfade { parts.append("crossfade \(crossfade.formatted(.number.precision(.fractionLength(0...1)))) s") }
            return parts.joined(separator: ", ")
        }
    }

    public init(codec: String, fileSampleRate: Double, fileBitDepth: Int?, fileChannels: Int,
                engineSampleRate: Double, deviceName: String, deviceSampleRate: Double,
                devicePhysicalFormat: String, devicePhysicalBits: Int? = nil, devicePhysicalIsFloat: Bool = false,
                isExclusive: Bool = false, processing: Processing? = nil) {
        self.codec = codec
        self.fileSampleRate = fileSampleRate
        self.fileBitDepth = fileBitDepth
        self.fileChannels = fileChannels
        self.engineSampleRate = engineSampleRate
        self.deviceName = deviceName
        self.deviceSampleRate = deviceSampleRate
        self.devicePhysicalFormat = devicePhysicalFormat
        self.devicePhysicalBits = devicePhysicalBits
        self.devicePhysicalIsFloat = devicePhysicalIsFloat
        self.isExclusive = isExclusive
        self.processing = processing
    }

    /// What reaches the device, in one word, for the quality label.
    public enum Verdict: Sendable, Equatable {
        /// Lossless samples arrive unchanged: native rate, and the device format holds every bit.
        case bitPerfect
        /// A lossy file at its own rate. Nothing resamples, but decoded MP3 or AAC has no
        /// original samples to preserve.
        case nativeRate
        case resampled(from: Double, to: Double)
        /// Native rate, but the device format has fewer bits than the file, so the low bits are lost.
        case reducedBitDepth(from: Int, to: Int)
        /// DSP mode: the samples go through EQ and gain on the way. (They may be resampled too;
        /// see `isResampled`.)
        case processed
        /// The app volume is below 100%, so the samples are scaled down on the way.
        case volumeScaled(percent: Int)
        /// DSD sent to the DAC as DoP: its bits arrive unchanged (the app volume doesn't apply).
        case dsdOverPCM
        /// DSD filtered down to PCM at `rate` (the device's rate, if it resampled that further).
        case dsdConverted(to: Double)
    }

    public var verdict: Verdict {
        if processing != nil { return .processed }
        if dsd?.isDoP == true { return .dsdOverPCM }
        if appVolume < 1 { return .volumeScaled(percent: Int((appVolume * 100).rounded())) }
        if dsd != nil { return .dsdConverted(to: deviceSampleRate) }
        if isResampled {
            return .resampled(from: fileSampleRate, to: deviceSampleRate)
        }
        guard let fileBits = fileBitDepth else { return .nativeRate }
        if let deviceBits = devicePhysicalBits {
            // A 32-bit float sample carries 24 bits exactly; integers carry their width.
            let carried = devicePhysicalIsFloat ? min(deviceBits, 24) : deviceBits
            if carried < fileBits { return .reducedBitDepth(from: fileBits, to: carried) }
        }
        return .bitPerfect
    }

    /// True when any stage runs at a different rate from the file.
    public var isResampled: Bool {
        // DSD always changes rate to become PCM; what counts is whether that PCM is resampled.
        if dsd != nil { return !FormatSelection.sameRate(engineSampleRate, deviceSampleRate) }
        return !FormatSelection.sameRate(fileSampleRate, deviceSampleRate)
            || !FormatSelection.sameRate(fileSampleRate, engineSampleRate)
    }

    public var fileDescription: String {
        if let dsd { return "\(dsd.name) (\(String(format: "%.1f", fileSampleRate / 1_000_000)) MHz)" }
        let depth = fileBitDepth.map { " \($0)-bit" } ?? ""
        return "\(codec) \(FormatSelection.formatRate(fileSampleRate))\(depth)"
    }

    public var deviceDescription: String {
        "\(deviceName) @ \(FormatSelection.formatRate(deviceSampleRate))"
    }

    public var summary: String {
        let verdict: String
        if let dsd {
            let pcm = FormatSelection.formatRate(engineSampleRate)
            verdict = dsd.isDoP ? "DoP at \(pcm)"
                : "converted to PCM \(pcm)" + (isResampled ? ", RESAMPLED to \(FormatSelection.formatRate(deviceSampleRate))" : "")
        } else if isResampled {
            verdict = "RESAMPLED (\(FormatSelection.formatRate(fileSampleRate)) → \(FormatSelection.formatRate(deviceSampleRate)))"
        } else {
            verdict = "native rate"
        }
        let dsp = processing.map { "; DSP: \($0.description)" } ?? ""
        let volume = appVolume < 1 ? "; app volume \(Int((appVolume * 100).rounded()))%" : ""
        return "\(fileDescription) → \(deviceDescription) [\(devicePhysicalFormat)] — \(verdict)\(dsp)\(volume)"
    }
}

extension SignalPath {
    init(file: TrackFile, url: URL, device: AudioDevice, engine: AVAudioEngine, processing: Processing? = nil) {
        let physical = (try? device.outputStreams().first)
            .flatMap { $0 }
            .flatMap { try? AudioDevice.physicalFormat(of: $0) }
        let codec: String, rate: Double, bits: Int?, channels: Int
        if let audioFile = file.audioFile {
            let asbd = audioFile.fileFormat.streamDescription.pointee
            codec = AudioCodec.name(asbd.mFormatID)
            rate = audioFile.fileFormat.sampleRate
            bits = TagReader.read(url)?.bitsPerSample ?? (asbd.mFormatID == kAudioFormatLinearPCM ? Int(asbd.mBitsPerChannel) : nil)
            channels = Int(audioFile.fileFormat.channelCount)
        } else {
            codec = file.dsd?.name ?? "DSD"
            rate = Double(file.dsd?.sampleRate ?? 0)
            bits = 1
            channels = file.dsd?.channels ?? Int(file.processingFormat.channelCount)
        }
        self.init(
            codec: codec,
            fileSampleRate: rate,
            fileBitDepth: bits,
            fileChannels: channels,
            engineSampleRate: engine.outputNode.inputFormat(forBus: 0).sampleRate,
            deviceName: device.name,
            deviceSampleRate: (try? device.nominalSampleRate()) ?? 0,
            devicePhysicalFormat: physical.map(FormatSelection.describe) ?? "unknown",
            devicePhysicalBits: physical.map { Int($0.mBitsPerChannel) },
            devicePhysicalIsFloat: physical.map(FormatSelection.isFloat) ?? false,
            isExclusive: device.hogModeOwner() == getpid(),
            processing: processing
        )
        if let dsd = file.dsd { self.dsd = DSD(name: dsd.name, isDoP: file.kind == .dop) }
    }
}

public enum AudioCodec {
    public static func name(_ id: AudioFormatID) -> String {
        switch id {
        case kAudioFormatFLAC: "FLAC"
        case kAudioFormatAppleLossless: "ALAC"
        case kAudioFormatMPEGLayer3: "MP3"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
             kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD: "AAC"
        case kAudioFormatLinearPCM: "PCM"
        default: "Unknown"
        }
    }
}

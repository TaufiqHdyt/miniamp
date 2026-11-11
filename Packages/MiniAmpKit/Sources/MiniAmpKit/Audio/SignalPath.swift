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

    /// DSP mode's stage between the player and the output.
    public struct Processing: Sendable, Equatable {
        /// The EQ preset ("Custom" if none matches), or nil when the EQ is off or flat.
        public var equalizer: String?
        public var replayGain: ReplayGain.Mode
        /// Whether the track has ReplayGain values (from its tags or an analysis).
        public var trackHasReplayGain: Bool
        /// Everything the samples are turned up or down by, dB: ReplayGain and the preamps.
        public var gain: Double

        public init(equalizer: String?, replayGain: ReplayGain.Mode, trackHasReplayGain: Bool, gain: Double) {
            self.equalizer = equalizer
            self.replayGain = replayGain
            self.trackHasReplayGain = trackHasReplayGain
            self.gain = gain
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
    }

    public var verdict: Verdict {
        if processing != nil { return .processed }
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
        !FormatSelection.sameRate(fileSampleRate, deviceSampleRate)
            || !FormatSelection.sameRate(fileSampleRate, engineSampleRate)
    }

    public var fileDescription: String {
        let depth = fileBitDepth.map { " \($0)-bit" } ?? ""
        return "\(codec) \(FormatSelection.formatRate(fileSampleRate))\(depth)"
    }

    public var deviceDescription: String {
        "\(deviceName) @ \(FormatSelection.formatRate(deviceSampleRate))"
    }

    public var summary: String {
        let verdict = isResampled
            ? "RESAMPLED (\(FormatSelection.formatRate(fileSampleRate)) → \(FormatSelection.formatRate(deviceSampleRate)))"
            : "native rate"
        let dsp = processing.map { "; DSP: \($0.description)" } ?? ""
        return "\(fileDescription) → \(deviceDescription) [\(devicePhysicalFormat)] — \(verdict)\(dsp)"
    }
}

extension SignalPath {
    init(file: AVAudioFile, url: URL, device: AudioDevice, engine: AVAudioEngine, processing: Processing? = nil) {
        let asbd = file.fileFormat.streamDescription.pointee
        let physical = (try? device.outputStreams().first)
            .flatMap { $0 }
            .flatMap { try? AudioDevice.physicalFormat(of: $0) }
        self.init(
            codec: AudioCodec.name(asbd.mFormatID),
            fileSampleRate: file.fileFormat.sampleRate,
            fileBitDepth: TagReader.read(url)?.bitsPerSample
                ?? (asbd.mFormatID == kAudioFormatLinearPCM ? Int(asbd.mBitsPerChannel) : nil),
            fileChannels: Int(file.fileFormat.channelCount),
            engineSampleRate: engine.outputNode.inputFormat(forBus: 0).sampleRate,
            deviceName: device.name,
            deviceSampleRate: (try? device.nominalSampleRate()) ?? 0,
            devicePhysicalFormat: physical.map(FormatSelection.describe) ?? "unknown",
            devicePhysicalBits: physical.map { Int($0.mBitsPerChannel) },
            devicePhysicalIsFloat: physical.map(FormatSelection.isFloat) ?? false,
            isExclusive: device.hogModeOwner() == getpid(),
            processing: processing
        )
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

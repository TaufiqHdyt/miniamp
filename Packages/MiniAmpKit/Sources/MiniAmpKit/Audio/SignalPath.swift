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

    public init(codec: String, fileSampleRate: Double, fileBitDepth: Int?, fileChannels: Int,
                engineSampleRate: Double, deviceName: String, deviceSampleRate: Double,
                devicePhysicalFormat: String) {
        self.codec = codec
        self.fileSampleRate = fileSampleRate
        self.fileBitDepth = fileBitDepth
        self.fileChannels = fileChannels
        self.engineSampleRate = engineSampleRate
        self.deviceName = deviceName
        self.deviceSampleRate = deviceSampleRate
        self.devicePhysicalFormat = devicePhysicalFormat
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
        return "\(fileDescription) → \(deviceDescription) [\(devicePhysicalFormat)] — \(verdict)"
    }
}

extension SignalPath {
    init(file: AVAudioFile, url: URL, device: AudioDevice, engine: AVAudioEngine) {
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
            devicePhysicalFormat: physical.map(FormatSelection.describe) ?? "unknown"
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

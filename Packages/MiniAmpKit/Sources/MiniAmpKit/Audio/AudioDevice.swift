import CoreAudio
import Foundation

/// An output device as seen by the Core Audio HAL. Values are read live, never cached.
public struct AudioDevice: Sendable, Hashable, Identifiable {
    public let id: AudioObjectID

    public init(id: AudioObjectID) { self.id = id }

    public static func defaultOutput() throws -> AudioDevice {
        let id = try HAL.get(AudioObjectID(kAudioObjectSystemObject),
                             .init(kAudioHardwarePropertyDefaultOutputDevice),
                             initial: AudioObjectID(kAudioObjectUnknown))
        guard id != kAudioObjectUnknown else {
            throw CoreAudioError(status: kAudioHardwareBadDeviceError, operation: "Find default output device")
        }
        return AudioDevice(id: id)
    }

    public var name: String {
        (try? HAL.getString(id, .init(kAudioObjectPropertyName))) ?? "Unknown device"
    }

    public var uid: String {
        (try? HAL.getString(id, .init(kAudioDevicePropertyDeviceUID))) ?? ""
    }

    // MARK: Sample rate

    public func nominalSampleRate() throws -> Double {
        try HAL.get(id, .init(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))
    }

    public func availableNominalSampleRates() throws -> [ClosedRange<Double>] {
        try HAL.getArray(id, .init(kAudioDevicePropertyAvailableNominalSampleRates), of: AudioValueRange.self)
            .map { $0.mMinimum...$0.mMaximum }
    }

    public func supports(sampleRate: Double) throws -> Bool {
        FormatSelection.contains(try availableNominalSampleRates(), sampleRate)
    }

    /// Sets the nominal rate and returns once the device reports it.
    public func setNominalSampleRate(_ rate: Double, timeout: Duration = .seconds(3)) async throws {
        let device = self
        try await HAL.change(
            id, .init(kAudioDevicePropertyNominalSampleRate),
            timeout: timeout, operation: "sample rate \(rate) Hz",
            until: { FormatSelection.sameRate((try? device.nominalSampleRate()) ?? 0, rate) }
        ) {
            try HAL.set(id, .init(kAudioDevicePropertyNominalSampleRate), Float64(rate))
        }
    }

    // MARK: Streams and physical format

    public func outputStreams() throws -> [AudioStreamID] {
        try HAL.getArray(id, .init(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput), of: AudioStreamID.self)
    }

    public static func physicalFormat(of stream: AudioStreamID) throws -> AudioStreamBasicDescription {
        try HAL.get(stream, .init(kAudioStreamPropertyPhysicalFormat), initial: AudioStreamBasicDescription())
    }

    public static func availablePhysicalFormats(of stream: AudioStreamID) throws -> [AudioStreamRangedDescription] {
        try HAL.getArray(stream, .init(kAudioStreamPropertyAvailablePhysicalFormats), of: AudioStreamRangedDescription.self)
    }

    /// Sets a stream's physical format and returns once the stream reports it.
    public static func setPhysicalFormat(
        _ format: AudioStreamBasicDescription, of stream: AudioStreamID, timeout: Duration = .seconds(3)
    ) async throws {
        try await HAL.change(
            stream, .init(kAudioStreamPropertyPhysicalFormat),
            timeout: timeout, operation: "physical format \(FormatSelection.describe(format))",
            until: { (try? physicalFormat(of: stream)).map { FormatSelection.matches($0, format) } ?? false }
        ) {
            try HAL.set(stream, .init(kAudioStreamPropertyPhysicalFormat), format)
        }
    }
}

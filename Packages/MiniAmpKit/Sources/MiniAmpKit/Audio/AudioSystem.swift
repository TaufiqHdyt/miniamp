import CoreAudio
import Foundation

/// System-wide device queries and change notifications.
public enum AudioSystem {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    /// Devices with at least one output stream, in HAL order.
    public static func outputDevices() throws -> [AudioDevice] {
        try HAL.getArray(system, .init(kAudioHardwarePropertyDevices), of: AudioObjectID.self)
            .map(AudioDevice.init(id:))
            .filter { ((try? $0.outputStreams()) ?? []).isEmpty == false }
    }

    public static func device(uid: String) -> AudioDevice? {
        (try? outputDevices())?.first { $0.uid == uid }
    }

    /// Yields when devices appear or disappear, or the default output changes.
    public static func deviceChanges() -> AsyncStream<Void> {
        HAL.changes(system, [
            .init(kAudioHardwarePropertyDevices),
            .init(kAudioHardwarePropertyDefaultOutputDevice),
        ])
    }
}

// MARK: - Liveness

extension AudioDevice {
    /// False once the device has been unplugged or removed.
    public var isAlive: Bool {
        let alive = (try? HAL.get(id, .init(kAudioDevicePropertyDeviceIsAlive), initial: UInt32(0))) ?? 0
        return alive != 0 && ((try? AudioSystem.outputDevices()) ?? []).contains(self)
    }

    public var outputChannelCount: Int {
        let streams = (try? outputStreams()) ?? []
        return streams.reduce(0) { sum, stream in
            sum + Int((try? AudioDevice.physicalFormat(of: stream).mChannelsPerFrame) ?? 0)
        }
    }
}

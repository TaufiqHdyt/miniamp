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

// MARK: - Liveness, hog mode, volume

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

    // Hog mode: exclusive access. Other apps (and system sounds) can't use the device.

    /// The process holding hog mode, or nil when the device is shared.
    public func hogModeOwner() -> pid_t? {
        let pid = (try? HAL.get(id, .init(kAudioDevicePropertyHogMode), initial: pid_t(-1))) ?? -1
        return pid == -1 ? nil : pid
    }

    public var supportsHogMode: Bool {
        HAL.isSettable(id, .init(kAudioDevicePropertyHogMode))
    }

    /// Takes or releases exclusive access for this process. The HAL toggles ownership on each set,
    /// so this only writes when the current state differs.
    public func setHogMode(_ on: Bool) throws {
        let mine = getpid()
        let owner = hogModeOwner()
        if on {
            if owner == mine { return }
            if let owner {
                throw CoreAudioError(status: kAudioDevicePermissionsError,
                                     operation: "Hog \(name) (held by pid \(owner))")
            }
        } else if owner != mine {
            return
        }
        try HAL.set(id, .init(kAudioDevicePropertyHogMode), on ? mine : pid_t(-1))
    }

    // Volume: the device's own control, so samples are never scaled in software.

    /// The elements that carry a settable volume: the main element if it has one, otherwise
    /// each output channel.
    private func volumeElements() -> [AudioObjectPropertyElement] {
        let main = AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput,
                                              kAudioObjectPropertyElementMain)
        if HAL.isSettable(id, main) { return [kAudioObjectPropertyElementMain] }
        let channels = max(outputChannelCount, 2)
        return (1...UInt32(channels)).filter {
            HAL.isSettable(id, .init(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, $0))
        }
    }

    public var hasVolumeControl: Bool { !volumeElements().isEmpty }

    /// 0...1, or nil when the device has no volume control (common on DACs: use the DAC's knob).
    public func volume() -> Float? {
        let values = volumeElements().compactMap {
            try? HAL.get(id, .init(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, $0),
                         initial: Float32(0))
        }
        return values.isEmpty ? nil : values.reduce(0, +) / Float(values.count)
    }

    public func setVolume(_ value: Float) throws {
        let clamped = min(max(value, 0), 1)
        for element in volumeElements() {
            try HAL.set(id, .init(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, element),
                        Float32(clamped))
        }
    }

    /// Yields when the device's volume or mute changes, from us or from anywhere else (volume keys).
    public func volumeChanges() -> AsyncStream<Void> {
        var addresses = [AudioObjectPropertyAddress(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput,
                                                    kAudioObjectPropertyElementMain)]
        for element in [kAudioObjectPropertyElementMain] + (1...UInt32(max(outputChannelCount, 2))).map({ $0 }) {
            addresses.append(.init(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, element))
        }
        return HAL.changes(id, addresses.filter { HAL.has(id, $0) })
    }
}

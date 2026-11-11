import CoreAudio
import Foundation
import os

/// Prepares an output device for a file: hog mode, then the nominal rate, then the deepest
/// physical format at that rate.
public enum DeviceConfigurator {
    static let log = Logger(subsystem: "dev.miniamp", category: "device")

    /// Taking or releasing hog mode on the default device changes the system default output
    /// (a hogged device can't be anyone's default). AVAudioEngine follows the default, and if
    /// that change reaches it while it's starting, it stalls for seconds. Wait for the change
    /// here, while the engine is stopped, so it's absorbed before the engine starts.
    static func waitForDefaultOutputToSettle(after device: AudioDevice) async {
        let start = ContinuousClock.now
        var last = try? AudioDevice.defaultOutput()
        var stableSince = start
        while ContinuousClock.now - start < .seconds(1) {
            try? await Task.sleep(for: .milliseconds(20))
            let now = try? AudioDevice.defaultOutput()
            if now != last {
                last = now
                stableSince = .now
            } else if ContinuousClock.now - stableSince >= .milliseconds(150) {
                break
            }
        }
        log.debug("default output settled after \((ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds])), privacy: .public): \(last?.name ?? "none", privacy: .public)")
    }

    /// Configures `device` for a file at `sampleRate` and returns the rate the device ends up at.
    ///
    /// When the device can't run at the file's rate, it's set to `FormatSelection.fallbackRate`
    /// and the output unit resamples. With `keepRate`, the device's current rate is accepted as is
    /// (another app chose it mid-track; fighting over it would never end). Throws if the device
    /// can't be put in the requested state; playback can still go ahead, and the signal path
    /// reports what the device is really doing.
    @discardableResult
    public static func configure(_ device: AudioDevice, sampleRate: Double, hogMode: Bool = false,
                                 keepRate: Bool = false) async throws -> Double {
        if hogMode != (device.hogModeOwner() == getpid()) {
            log.info("Hog mode \(hogMode ? "on" : "off", privacy: .public) for \(device.name, privacy: .public)")
            try device.setHogMode(hogMode)
            await waitForDefaultOutputToSettle(after: device)
        }

        let ranges = try device.availableNominalSampleRates()
        let target = FormatSelection.fallbackRate(for: sampleRate, supported: ranges) ?? sampleRate
        if !FormatSelection.sameRate(target, sampleRate) {
            log.notice("\(device.name, privacy: .public) can't do \(sampleRate) Hz; using \(target) Hz and resampling")
        }
        let current = try device.nominalSampleRate()
        if keepRate {
            log.notice("Keeping \(device.name, privacy: .public) at \(current) Hz, set by another app")
        } else if !FormatSelection.sameRate(current, target) {
            log.info("Switching \(device.name, privacy: .public) from \(current) to \(target) Hz")
            try await device.setNominalSampleRate(target)
        }

        let rate = try device.nominalSampleRate()
        for stream in try device.outputStreams() {
            let currentFormat = try AudioDevice.physicalFormat(of: stream)
            guard let best = FormatSelection.bestPhysicalFormat(
                from: try AudioDevice.availablePhysicalFormats(of: stream),
                sampleRate: rate,
                channels: currentFormat.mChannelsPerFrame,
                allowNonMixable: hogMode
            ) else { continue }
            if !FormatSelection.matches(best, currentFormat) {
                log.info("Stream \(stream) physical format → \(FormatSelection.describe(best), privacy: .public)")
                try await AudioDevice.setPhysicalFormat(best, of: stream)
            }
        }
        return rate
    }
}

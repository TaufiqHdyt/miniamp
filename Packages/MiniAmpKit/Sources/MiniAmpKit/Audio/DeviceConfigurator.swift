import CoreAudio
import Foundation
import os

/// Prepares an output device for a file: the nominal rate first, then the deepest physical
/// format at that rate.
public enum DeviceConfigurator {
    static let log = Logger(subsystem: "dev.miniamp", category: "device")

    /// Configures `device` for a file at `sampleRate` and returns the rate the device ends up at.
    ///
    /// When the device can't run at the file's rate, it's set to `FormatSelection.fallbackRate`
    /// and the output unit resamples. Throws if the device can't be put in the requested state;
    /// playback can still go ahead, and the signal path reports what the device is really doing.
    @discardableResult
    public static func configure(_ device: AudioDevice, sampleRate: Double) async throws -> Double {
        let ranges = try device.availableNominalSampleRates()
        let target = FormatSelection.fallbackRate(for: sampleRate, supported: ranges) ?? sampleRate
        if !FormatSelection.sameRate(target, sampleRate) {
            log.notice("\(device.name, privacy: .public) can't do \(sampleRate) Hz; using \(target) Hz and resampling")
        }
        let current = try device.nominalSampleRate()
        if !FormatSelection.sameRate(current, target) {
            log.info("Switching \(device.name, privacy: .public) from \(current) to \(target) Hz")
            try await device.setNominalSampleRate(target)
        }

        let rate = try device.nominalSampleRate()
        for stream in try device.outputStreams() {
            let currentFormat = try AudioDevice.physicalFormat(of: stream)
            guard let best = FormatSelection.bestPhysicalFormat(
                from: try AudioDevice.availablePhysicalFormats(of: stream),
                sampleRate: rate,
                channels: currentFormat.mChannelsPerFrame
            ) else { continue }
            if !FormatSelection.matches(best, currentFormat) {
                log.info("Stream \(stream) physical format → \(FormatSelection.describe(best), privacy: .public)")
                try await AudioDevice.setPhysicalFormat(best, of: stream)
            }
        }
        return rate
    }
}

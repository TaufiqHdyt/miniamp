import CoreAudio
import Foundation
import os

/// Prepares an output device for a file: nominal rate first, then the deepest physical format at that rate.
public enum DeviceConfigurator {
    static let log = Logger(subsystem: "dev.miniamp", category: "device")

    /// Throws if the device can't be put in the requested state. Playback can still go ahead;
    /// the signal path will then report the mismatch.
    public static func configure(_ device: AudioDevice, sampleRate: Double) async throws {
        if try device.supports(sampleRate: sampleRate) {
            let current = try device.nominalSampleRate()
            if !FormatSelection.sameRate(current, sampleRate) {
                log.info("Switching \(device.name, privacy: .public) from \(current) to \(sampleRate) Hz")
                try await device.setNominalSampleRate(sampleRate)
            }
        } else {
            // Fallback rate selection is M2 (issue: fallback when the device can't do the file's rate).
            log.notice("\(device.name, privacy: .public) doesn't support \(sampleRate) Hz; leaving rate unchanged")
        }

        let rate = try device.nominalSampleRate()
        for stream in try device.outputStreams() {
            let current = try AudioDevice.physicalFormat(of: stream)
            guard let best = FormatSelection.bestPhysicalFormat(
                from: try AudioDevice.availablePhysicalFormats(of: stream),
                sampleRate: rate,
                channels: current.mChannelsPerFrame
            ) else { continue }
            if !FormatSelection.matches(best, current) {
                log.info("Stream \(stream) physical format → \(FormatSelection.describe(best), privacy: .public)")
                try await AudioDevice.setPhysicalFormat(best, of: stream)
            }
        }
    }
}

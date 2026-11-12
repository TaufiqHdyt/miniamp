import Foundation
import MiniAmpKit

/// Playback settings that survive a relaunch.
enum Preferences {
    static let outputDeviceKey = "outputDeviceUID"
    static let hogModeKey = "hogMode"
    static let dspModeKey = "dspMode"
    static let equalizerKey = "equalizer"
    static let replayGainModeKey = "replayGainMode"
    static let replayGainPreampKey = "replayGainPreamp"
    static let preventsClippingKey = "preventsClipping"
    static let appVolumeKey = "appVolume"

    @MainActor
    static func apply(to player: Player) {
        let defaults = UserDefaults.standard
        player.preferredDeviceUID = defaults.string(forKey: outputDeviceKey)
        player.hogMode = defaults.bool(forKey: hogModeKey)
        player.dspMode = defaults.bool(forKey: dspModeKey)
        if let data = defaults.data(forKey: equalizerKey), let eq = try? JSONDecoder().decode(Equalizer.self, from: data) {
            player.equalizer = eq
        }
        player.replayGainMode = defaults.string(forKey: replayGainModeKey).flatMap(ReplayGain.Mode.init) ?? .off
        player.replayGainPreamp = defaults.double(forKey: replayGainPreampKey)
        player.preventsClipping = defaults.object(forKey: preventsClippingKey) as? Bool ?? true
        player.appVolume = (defaults.object(forKey: appVolumeKey) as? NSNumber)?.floatValue ?? 1
        saveDSPSettings(of: player)
    }

    /// Plays through `uid` (nil follows the system default) and remembers the choice.
    @MainActor
    static func setOutputDevice(_ uid: String?, on player: Player) {
        player.preferredDeviceUID = uid
        UserDefaults.standard.set(uid, forKey: outputDeviceKey)
    }

    /// Saves the DSP settings and the app volume now and whenever they change, wherever from.
    @MainActor
    private static func saveDSPSettings(of player: Player) {
        withObservationTracking {
            let defaults = UserDefaults.standard
            defaults.set(player.dspMode, forKey: dspModeKey)
            defaults.set(try? JSONEncoder().encode(player.equalizer), forKey: equalizerKey)
            defaults.set(player.replayGainMode.rawValue, forKey: replayGainModeKey)
            defaults.set(player.replayGainPreamp, forKey: replayGainPreampKey)
            defaults.set(player.preventsClipping, forKey: preventsClippingKey)
            defaults.set(player.appVolume, forKey: appVolumeKey)
        } onChange: {
            Task { @MainActor in saveDSPSettings(of: player) }
        }
    }

    // MARK: Backups

    /// The app's own settings, for a backup: everything in its defaults except what the
    /// system keeps there (window frames, panel state) and launch-argument test hooks.
    static func exportable() -> [String: Any] {
        guard let domain = Bundle.main.bundleIdentifier.flatMap(UserDefaults.standard.persistentDomain(forName:)) else { return [:] }
        return domain.filter { key, _ in !excludedPrefixes.contains { key.hasPrefix($0) } && !testHooks.contains(key) }
    }

    /// Applies settings from a backup.
    static func importSettings(_ settings: [String: Any]) {
        let defaults = UserDefaults.standard
        for (key, value) in settings where !excludedPrefixes.contains(where: { key.hasPrefix($0) }) && !testHooks.contains(key) {
            defaults.set(value, forKey: key)
        }
    }

    private static let excludedPrefixes = ["NS", "Apple", "com.apple."]
    private static let testHooks: Set<String> = ["libraryDatabase", "libraryFolder", "autoplay", "sidebar", "hog",
                                                  "sleepAtEndOfTrack", "logHangs"]
}

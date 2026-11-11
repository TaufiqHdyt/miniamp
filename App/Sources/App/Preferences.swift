import Foundation
import MiniAmpKit

/// Playback settings that survive a relaunch.
enum Preferences {
    static let outputDeviceKey = "outputDeviceUID"
    static let hogModeKey = "hogMode"

    @MainActor
    static func apply(to player: Player) {
        let defaults = UserDefaults.standard
        player.preferredDeviceUID = defaults.string(forKey: outputDeviceKey)
        player.hogMode = defaults.bool(forKey: hogModeKey)
    }

    /// Plays through `uid` (nil follows the system default) and remembers the choice.
    @MainActor
    static func setOutputDevice(_ uid: String?, on player: Player) {
        player.preferredDeviceUID = uid
        UserDefaults.standard.set(uid, forKey: outputDeviceKey)
    }
}

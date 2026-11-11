import MiniAmpKit
import os
import SwiftUI

@main
struct MiniAmpApp: App {
    @State private var app: AppState = {
        let library: Library?
        do {
            library = Library(database: try AppDatabase.onDisk(), artwork: try? ArtworkCache.standard())
        } catch {
            Logger(subsystem: "dev.miniamp", category: "library").error("can't open the library: \(error, privacy: .public)")
            library = nil
        }
        let player = Player()
        Preferences.apply(to: player)
        return AppState(player: player, library: library)
    }()

    var body: some Scene {
        Window("miniamp", id: "main") {
            MainWindow(app: app)
        }
        .defaultSize(width: 1180, height: 760)
        .commands { AppCommands(app: app) }

        Settings {
            SettingsView(app: app)
        }
    }
}

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
}

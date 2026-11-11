import MiniAmpKit
import os
import SwiftUI

@main
struct MiniAmpApp: App {
    @State private var app: AppState = {
        let library: Library?
        do {
            var database = AppDatabase.onDisk
            var artwork = { try? ArtworkCache.standard() }
            // For performance checks (in any build), so a test library never touches the real one:
            //   miniamp -libraryDatabase /path/in/container/test.sqlite [-logHangs YES]
            if let path = UserDefaults.standard.string(forKey: "libraryDatabase") {
                let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
                database = { _ in try AppDatabase.at(path) }
                artwork = { try? ArtworkCache(directory: dir.appendingPathComponent("artwork", isDirectory: true)) }
            }
            MainThreadWatchdog.startIfWanted()
            library = Library(database: try database(.default), artwork: artwork())
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
        // Open at launch even if the window was closed when the app last quit.
        .defaultLaunchBehavior(.presented)
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

    /// Plays through `uid` (nil follows the system default) and remembers the choice.
    @MainActor
    static func setOutputDevice(_ uid: String?, on player: Player) {
        player.preferredDeviceUID = uid
        UserDefaults.standard.set(uid, forKey: outputDeviceKey)
    }
}

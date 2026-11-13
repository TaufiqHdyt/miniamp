import MiniAmpKit
import os
import SwiftUI

@main
struct MiniAmpApp: App {
    @State private var app: AppState = {
        let library: Library?
        var launchError: String?
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
            let opened = try database(.default)
            let cache = artwork()
            // A backup chosen with Restore from Backup… (only into the real library).
            if UserDefaults.standard.string(forKey: "libraryDatabase") == nil {
                launchError = Backups.restorePending(into: opened, artwork: cache)
            }
            library = Library(database: opened, artwork: cache)
        } catch {
            Logger(subsystem: "dev.miniamp", category: "library").error("can't open the library: \(error, privacy: .public)")
            library = nil
        }
        let player = Player()
        Preferences.apply(to: player)
        let state = AppState(player: player, library: library)
        state.error = launchError
        return state
    }()

    var body: some Scene {
        Window("miniamp", id: "main") {
            MainWindow(app: app)
        }
        .defaultSize(width: 1180, height: 760)
        // Open at launch even if the window was closed when the app last quit.
        .defaultLaunchBehavior(.presented)
        .commands { AppCommands(app: app) }

        Window("Equalizer", id: "equalizer") {
            EqualizerView(player: app.player)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView(app: app)
        }
    }
}

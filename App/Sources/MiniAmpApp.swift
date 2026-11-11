import MiniAmpKit
import os
import SwiftUI

@main
struct MiniAmpApp: App {
    /// Nil if the database can't be opened; the player still works without it.
    @State private var library: Library? = {
        do {
            return Library(database: try AppDatabase.onDisk(), artwork: try? ArtworkCache.standard())
        } catch {
            Logger(subsystem: "dev.miniamp", category: "library").error("can't open the library: \(error, privacy: .public)")
            return nil
        }
    }()

    var body: some Scene {
        WindowGroup("miniamp") {
            ContentView(library: library)
        }
    }
}

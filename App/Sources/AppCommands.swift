import MiniAmpKit
import SwiftUI

struct AppCommands: Commands {
    let app: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { app.importingFiles = true }
                .keyboardShortcut("o")
            Button("Add Music Folder…") { app.addingFolder = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(app.library == nil)
        }
        CommandGroup(replacing: .textEditing) {
            Button("Find") { app.searchFocusRequests += 1 }
                .keyboardShortcut("f")
                .disabled(app.library == nil)
        }
        CommandGroup(before: .sidebar) {
            Button(app.showsNowPlaying ? "Hide Now Playing" : "Show Now Playing") { app.showsNowPlaying.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
        }
        CommandMenu("Controls") {
            let player = app.player
            // Space also plays and pauses, unless a text field has focus.
            Button(player.state == .playing ? "Pause" : "Play") {
                app.perform { try await player.togglePlayPause() }
            }
            .disabled(player.queue.isEmpty)
            Button("Stop") { player.stop() }
                .keyboardShortcut(".")
                .disabled(player.state == .stopped)
            Divider()
            Button("Next") { app.perform { try await player.next() } }
                .keyboardShortcut(.rightArrow)
            Button("Previous") { app.perform { try await player.previous() } }
                .keyboardShortcut(.leftArrow)
            Divider()
            Toggle("Shuffle", isOn: Binding(get: { player.isShuffled }, set: { player.setShuffle($0) }))
            Picker("Repeat", selection: Binding(get: { player.repeatMode }, set: { player.repeatMode = $0 })) {
                ForEach(PlayQueue<URL>.Repeat.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Divider()
            Menu("Sleep Timer") { SleepTimerChoices(timer: app.sleepTimer) }
            Divider()
            Button("Volume Up") { if let v = player.volume { player.setVolume(min(v + 0.0625, 1)) } }
                .keyboardShortcut(.upArrow)
                .disabled(player.volume == nil)
            Button("Volume Down") { if let v = player.volume { player.setVolume(max(v - 0.0625, 0)) } }
                .keyboardShortcut(.downArrow)
                .disabled(player.volume == nil)
        }
    }
}

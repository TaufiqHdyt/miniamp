import MiniAmpKit
import SwiftUI

struct AppCommands: Commands {
    let app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Playlist") { app.newPlaylist() }
                .keyboardShortcut("n")
                .disabled(app.library == nil)
            Divider()
            Button("Open…") { app.importingFiles = true }
                .keyboardShortcut("o")
            Button("Add Music Folder…") { app.addingFolder = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(app.library == nil)
            Divider()
            Button("Back Up Library…") { Backups.backUp(app) }
                .disabled(app.library == nil)
            Button("Restore from Backup…") { Backups.chooseRestore(app) }
                .disabled(app.library == nil)
        }
        CommandGroup(replacing: .textEditing) {
            Button("Find") { app.searchFocusRequests += 1 }
                .keyboardShortcut("f")
                .disabled(app.library == nil)
        }
        CommandGroup(before: .sidebar) {
            Button(app.isShowing(.upNext) ? "Hide Up Next" : "Show Up Next") { app.toggle(.upNext) }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button(app.isShowing(.lyrics) ? "Hide Lyrics" : "Show Lyrics") { app.toggle(.lyrics) }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Button(app.showsFullLyrics ? "Hide Full Lyrics" : "Show Full Lyrics") { app.toggleFullLyrics() }
                .keyboardShortcut("l", modifiers: [.command, .option, .shift])
                .disabled(!app.showsFullLyrics && app.currentURL == nil)
            Button(app.showsVisualizer ? "Hide Visualizer" : "Show Visualizer") { app.toggleVisualizer() }
                .keyboardShortcut("v", modifiers: [.command, .option, .shift])
                .disabled(!app.showsVisualizer && app.currentURL == nil)
            Button("Edit Lyrics…") { app.editLyrics() }
                .disabled(app.currentURL == nil || app.library == nil)
            Menu("Lyrics Timing") {
                Button("Show Lyrics Sooner") { app.adjustLyricsTiming(by: AppState.lyricsStep) }
                    .keyboardShortcut("[", modifiers: [.command, .option])
                Button("Show Lyrics Later") { app.adjustLyricsTiming(by: .zero - AppState.lyricsStep) }
                    .keyboardShortcut("]", modifiers: [.command, .option])
                Divider()
                Button("Reset for This Song") { app.adjustLyricsTiming(by: nil) }
                    .disabled(app.currentURL.map { app.lyricsOffset(for: $0) == .zero } ?? true)
            }
            .disabled(app.currentURL == nil)
            Toggle("Tint with Album Artwork", isOn: Binding(get: { app.tintsWithArtwork }, set: { app.tintsWithArtwork = $0 }))
            Button("Listening Stats") { app.sidebarRequest = .stats }
                .disabled(app.library == nil)
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
            Toggle("DSP Mode", isOn: Binding(get: { player.dspMode }, set: { player.dspMode = $0 }))
            Button("Equalizer…") { app.showEqualizer(openWindow) }
                .keyboardShortcut("e", modifiers: [.command, .option])
            Picker("ReplayGain", selection: Binding(get: { player.replayGainMode }, set: { player.replayGainMode = $0 })) {
                ForEach(ReplayGain.Mode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Divider()
            Button("Volume Up") { player.appVolume += 0.0625 }
                .keyboardShortcut(.upArrow)
                .disabled(player.appVolume >= 1)
            Button("Volume Down") { player.appVolume -= 0.0625 }
                .keyboardShortcut(.downArrow)
                .disabled(player.appVolume <= 0)
        }
    }
}

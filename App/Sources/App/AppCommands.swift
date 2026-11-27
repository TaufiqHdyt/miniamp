import MiniAmpKit
import SwiftUI

struct AppCommands: Commands {
    let app: AppState
    @AppStorage("showsLibrarySidebar") private var showsSidebar = true
    private func command(_ action: AppAction, title: String? = nil) -> some View {
        Button(title ?? action.rawValue) { app.run(action) }
            .keyboardShortcut(action.windowKey ? nil : action.shortcut)
            .disabled(!action.isEnabled(in: app))
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            command(.newPlaylist)
            Divider()
            command(.open, title: "Open…")
            command(.openFolder)
            command(.addFolder)
            Divider()
            Button("Back Up Library…") { Backups.backUp(app) }
                .disabled(app.library == nil)
            Button("Open Backup…") { Backups.chooseBackup(app) }
                .disabled(app.library == nil)
        }
        CommandGroup(replacing: .textEditing) {
            command(.find, title: "Find")
        }
        CommandGroup(replacing: .sidebar) {
            Button(showsSidebar ? "Hide Sidebar" : "Show Sidebar") { showsSidebar.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(app.fullView != nil)
            Divider()
            command(.songs)
            command(.queue)
            command(.nowPlaying)
            command(.lyrics, title: app.showsFullLyrics ? "Hide Lyrics" : "Show Lyrics")
            command(.visualizer, title: app.showsVisualizer ? "Hide Visualizer" : "Show Visualizer")
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
            Toggle("Tint Listening Stats with Album Artwork", isOn: Binding(get: { app.tintsWithArtwork }, set: { app.tintsWithArtwork = $0 }))
            command(.stats)
            command(.duplicates)
            Divider()
        }
        CommandMenu("Controls") {
            let player = app.player
            let seekable = player.state == .playing || player.state == .paused
            command(.playPause, title: player.state == .playing ? "Pause" : "Play")
            command(.play)
            command(.pause)
            command(.stop)
            command(.stopAfterTrack, title: app.sleepTimer.mode == .endOfTrack
                    ? "Cancel Stop After This Track" : nil)
            Divider()
            command(.next)
            command(.previous)
            command(.jump)
            command(.jumpTime)
            Button("Skip Forward \(Int(AppState.skipStep)) Seconds") { app.skip(by: AppState.skipStep) }
                .disabled(!seekable)
            Button("Skip Back \(Int(AppState.skipStep)) Seconds") { app.skip(by: -AppState.skipStep) }
                .disabled(!seekable)
            Divider()
            Toggle("Shuffle", isOn: Binding(get: { player.isShuffled }, set: { player.setShuffle($0) }))
                .keyboardShortcut(AppAction.shuffle.shortcut)
            Picker("Repeat", selection: Binding(get: { player.repeatMode }, set: { player.repeatMode = $0 })) {
                ForEach(PlayQueue<URL>.Repeat.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            command(.repeatMode, title: "Change Repeat to \(player.repeatMode.next.label)")
            Divider()
            Menu("Sleep Timer") { SleepTimerChoices(timer: app.sleepTimer) }
            Divider()
            Toggle("DSP Mode", isOn: Binding(get: { player.dspMode }, set: { player.dspMode = $0 }))
            command(.equalizer)
            command(.output)
            Picker("ReplayGain", selection: Binding(get: { player.replayGainMode }, set: { player.replayGainMode = $0 })) {
                ForEach(ReplayGain.Mode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Divider()
            command(.volumeUp)
            command(.volumeDown)
            command(.mute, title: app.isMuted ? "Unmute" : "Mute")
        }
        CommandGroup(before: .help) {
            command(.commands)
            command(.shortcuts)
        }
    }
}

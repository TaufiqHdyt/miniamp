import MiniAmpKit
import SwiftUI

struct SettingsView: View {
    let app: AppState

    var body: some View {
        TabView {
            Tab("Library", systemImage: "music.note.house") {
                LibrarySettings(app: app)
            }
            Tab("Playback", systemImage: "hifispeaker") {
                PlaybackSettings(app: app, player: app.player)
            }
            Tab("Sound", systemImage: "slider.vertical.3") {
                SoundSettings(app: app, player: app.player)
            }
            Tab("Lyrics", systemImage: "quote.bubble") {
                LyricsSettings(app: app)
            }
        }
        .frame(width: 560)
    }
}

private struct LyricsSettings: View {
    @Bindable var app: AppState

    var body: some View {
        Form {
            Section {
                Text("Lyrics come from a .lrc file with the same name beside the song, or from the song's own tags. Synced lyrics follow along as it plays.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Stepper(value: Binding(get: { app.lyricsDelay.wholeMilliseconds },
                                       set: { app.lyricsDelay = .milliseconds($0) }),
                        in: 0...3000, step: 50) {
                    LabeledContent("Delay synced lyrics by", value: "\(app.lyricsDelay.wholeMilliseconds) ms")
                }
            } footer: {
                Text("For speakers that play the sound late, such as Bluetooth headphones (often 150 to 300 ms), where lyrics would otherwise show before you hear the words. It applies to every song, on top of the timing set for a song in the Lyrics pane.")
                    .foregroundStyle(.secondary).font(.caption)
            }
            Section {
                Toggle("Look up missing lyrics on LRCLIB", isOn: $app.looksUpLyricsOnline)
            } footer: {
                Text("When a song has no lyrics of its own, miniamp asks lrclib.net, sending the song's title, artist, album, and duration. What it finds is kept in the library, so each song is asked about once. With this off, you can still search for one song from the Lyrics pane.")
                    .foregroundStyle(.secondary).font(.caption)
            }
        }
        .formStyle(.grouped)
    }
}

private struct LibrarySettings: View {
    let app: AppState
    @State private var addingFolder = false

    var body: some View {
        Form {
            if let library = app.library {
                Section {
                    if library.folders.isEmpty {
                        Text("No folders yet. Add the folder your music is in; miniamp watches it for changes.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(library.folders) { folder in
                        HStack {
                            Image(systemName: "folder")
                            Text(folder.path).lineLimit(1).truncationMode(.middle).help(folder.path)
                            Spacer()
                            Button("Remove", role: .destructive) {
                                app.perform { try await library.removeFolder(folder) }
                            }
                            .help("Remove from the library. The files stay on disk.")
                        }
                    }
                } header: {
                    Text("Music folders")
                } footer: {
                    HStack {
                        Text(status(library)).foregroundStyle(.secondary).font(.caption)
                        Spacer()
                        Button("Rescan") { library.rescan() }.disabled(library.folders.isEmpty || library.progress != nil)
                        Button("Add Folder…") { addingFolder = true }
                    }
                }
                if let message = library.lastError {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            } else {
                Text("The library database couldn't be opened.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 300)
        .fileImporter(isPresented: $addingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): app.perform { try await app.library?.addFolder(url) }
            case .failure(let e): app.error = e.localizedDescription
            }
        }
    }

    private func status(_ library: Library) -> String {
        if let p = library.progress {
            return p.phase == .listing ? "Looking for changes…" : "Reading tags: \(p.filesRead) of \(p.filesToRead)"
        }
        var text = CountFormat.songs(library.trackCount)
        if let scan = library.lastScan {
            text += ". Last scan: \(scan.added) added, \(scan.updated) updated, \(scan.removed) removed"
            if scan.offloaded > 0 { text += ", \(scan.offloaded) only in iCloud" }
        }
        return text
    }
}

/// Bit-perfect or DSP mode, the EQ, and ReplayGain.
private struct SoundSettings: View {
    let app: AppState
    @Bindable var player: Player
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                Picker("Signal path", selection: $player.dspMode) {
                    Text("Bit-perfect").tag(false)
                    Text("DSP").tag(true)
                }
                .pickerStyle(.segmented)
                Text(player.dspMode
                     ? "Samples go through the equalizer, ReplayGain, and crossfade on the way to the device."
                     : "Samples reach the device unchanged. The equalizer, ReplayGain, and crossfade are off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Equalizer") {
                LabeledContent("Equalizer") {
                    HStack {
                        Text(player.equalizer.isEnabled ? player.equalizer.preset?.name ?? "Custom" : "Off")
                            .foregroundStyle(.secondary)
                        Button("Open Equalizer…") { app.showEqualizer(openWindow) }
                    }
                }
            }
            Section {
                Picker("ReplayGain", selection: $player.replayGainMode) {
                    ForEach(ReplayGain.Mode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                LabeledContent("Preamp") {
                    HStack {
                        Slider(value: $player.replayGainPreamp, in: -12...12, step: 0.5)
                            .frame(width: 180)
                        Text(String(format: "%+.1f dB", player.replayGainPreamp))
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                    }
                }
                .disabled(player.replayGainMode == .off)
                Toggle("Prevent clipping", isOn: $player.preventsClipping)
                    .disabled(player.replayGainMode == .off)
                    .help("Turns a track down less when its peaks would go past full scale")
                if let library = app.library { LoudnessAnalysisRow(library: library) }
            } header: {
                Text("ReplayGain")
            } footer: {
                Text("Plays tracks at the same loudness, using their ReplayGain tags or miniamp's own measurement. Album mode keeps the differences between an album's tracks. Applies in DSP mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            CrossfadeSection(app: app, player: player)
        }
        .formStyle(.grouped)
    }
}

/// How long songs overlap, and how the overlap is placed.
private struct CrossfadeSection: View {
    @Bindable var app: AppState
    @Bindable var player: Player

    var body: some View {
        Section {
            LabeledContent("Crossfade") {
                HStack {
                    Slider(value: $player.crossfadeDuration, in: 0...Player.maximumCrossfade, step: 1)
                        .frame(width: 180)
                    Text(player.crossfadeDuration > 0 ? "\(Int(player.crossfadeDuration)) s" : "Off")
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
            }
            Toggle(isOn: $player.crossfadeMatchesBeats) {
                Text("Fade on the beat")
                Text("Starts the fade on a beat of the ending song, for whole bars, and brings the next one in on its first beat.")
            }
            .disabled(player.crossfadeDuration == 0)
            Toggle(isOn: $app.keepsAlbumsGapless) {
                Text("Keep albums gapless")
                Text("No crossfade between songs from the same album.")
            }
            .disabled(player.crossfadeDuration == 0)
        } header: {
            Text("Crossfade")
        } footer: {
            Text("Overlaps the end of each song with the start of the next, skipping the silence between them. Applies in DSP mode, between songs of the same sample rate; others play gaplessly. Takes effect from the next song.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Measures tracks that have no ReplayGain yet, with progress while it runs.
private struct LoudnessAnalysisRow: View {
    let library: Library

    var body: some View {
        LabeledContent("Analysis") {
            if let p = library.loudnessProgress {
                HStack {
                    ProgressView(value: Double(p.tracksDone), total: Double(max(p.tracksTotal, 1)))
                        .frame(width: 140)
                    Text("\(p.tracksDone) of \(p.tracksTotal)").monospacedDigit().foregroundStyle(.secondary)
                    Button("Stop") { library.cancelLoudnessAnalysis() }
                }
            } else {
                Button("Analyze Unmeasured Songs") { library.analyzeLoudness() }
                    .help("Measures the loudness of songs with no ReplayGain tags. Takes a while for a big library; playback is unaffected.")
            }
        }
    }
}

private struct PlaybackSettings: View {
    @Bindable var app: AppState
    @Bindable var player: Player

    var body: some View {
        Form {
            Picker("Output device", selection: Binding(get: { player.preferredDeviceUID },
                                                       set: { Preferences.setOutputDevice($0, on: player) })) {
                Text("System default").tag(String?.none)
                ForEach(player.availableDevices) { device in
                    Text(device.name).tag(Optional(device.uid))
                }
            }
            Toggle(isOn: Binding(get: { player.hogMode }, set: { on in
                player.hogMode = on
                UserDefaults.standard.set(on, forKey: Preferences.hogModeKey)
            })) {
                Text("Exclusive access (hog mode)")
                Text("While playing, other apps can't use the device and system sounds don't mix in.")
            }
            Toggle(isOn: $player.sendsDSDAsDoP) {
                Text("Send DSD to the DAC as DoP")
                Text("For DACs that play DSD (DSD over PCM). In bit-perfect mode, on a device that runs at the DoP rate, DSF and DFF files reach the DAC as DSD; miniamp's volume doesn't apply. Otherwise they're converted to PCM. Turn this off if DSD plays as noise.")
            }
            LabeledContent("Sample rate") {
                Text("Matches each file. When the device can't play a file's rate, miniamp picks the closest rate it can and says so.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .formStyle(.grouped)
    }
}

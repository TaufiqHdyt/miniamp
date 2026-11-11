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
                PlaybackSettings(player: app.player)
            }
        }
        .frame(width: 560)
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
        var text = "\(library.trackCount) songs"
        if let scan = library.lastScan {
            text += ". Last scan: \(scan.added) added, \(scan.updated) updated, \(scan.removed) removed"
            if scan.offloaded > 0 { text += ", \(scan.offloaded) only in iCloud" }
        }
        return text
    }
}

private struct PlaybackSettings: View {
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
            LabeledContent("Sample rate") {
                Text("Matches each file. When the device can't play a file's rate, miniamp picks the closest rate it can and says so.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .formStyle(.grouped)
    }
}

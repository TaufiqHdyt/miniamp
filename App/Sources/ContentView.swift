import MiniAmpKit
import SwiftUI

/// Placeholder until M4. Shows that both dependencies are linked.
struct ContentView: View {
    @State private var sqlite = "?"

    var body: some View {
        VStack(spacing: 8) {
            Text("miniamp").font(.largeTitle.bold())
            Text("TagLib \(TagReader.tagLibVersion) · SQLite \(sqlite)")
                .foregroundStyle(.secondary)
                .monospaced()
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 300)
        .task { sqlite = (try? AppDatabase.inMemory().sqliteVersion) ?? "unavailable" }
    }
}

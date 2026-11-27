import AppKit
import MiniAmpKit
import SwiftUI

struct CommandPalette: View {
    let app: AppState
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let filter = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let actions = AppAction.allCases.filter {
            $0 != .commands && $0.isEnabled(in: app) && (filter.isEmpty || $0.rawValue.localizedStandardContains(filter))
        }
        KeyboardPicker(title: "Find a Command", prompt: "Search commands", query: $query, rows: actions) { action in
            app.commandAfterSheet = action
            dismiss()
        } label: { action in
            LabeledContent(action.rawValue, value: action.keys(classic: app.winampShortcuts))
        }
    }
}

struct JumpView: View {
    let app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var scope = Scope.queue
    @State private var libraryResults: [TrackInfo] = []
    @State private var queueMetadata: [URL: QueueEntry] = [:]

    private enum Scope: String, CaseIterable {
        case queue = "Queue"
        case library = "Library"
    }

    private struct Result: Identifiable {
        enum ID: Hashable {
            case queue(Int)
            case library(TrackInfo.ID)
        }

        let id: ID
        let entry: QueueEntry
        var track: TrackInfo? = nil
    }

    var body: some View {
        let queue = app.player.queue
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let results = scope == .queue ? queueResults(queue, matching: needle) : libraryResults.map {
            Result(id: .library($0.id), entry: QueueEntry($0, url: $0.track.url), track: $0)
        }
        return VStack(spacing: 0) {
            if app.library != nil {
                Picker("Search in", selection: $scope) {
                    ForEach(Scope.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top])
            }
            KeyboardPicker(title: "Jump to Song", prompt: "Search by title, artist, or album",
                           query: $query, rows: results) { result in
                switch result.id {
                case .queue(let item):
                    let player = app.player
                    guard player.queue.order.contains(item), player.queue.items[item] == result.entry.url else { return }
                    app.perform { try await player.jump(toItem: item) }
                case .library(let id):
                    guard let track = result.track else { return }
                    app.play([track], from: id)
                }
                dismiss()
            } label: { result in
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.entry.title).lineLimit(1)
                    if let subtitle = result.entry.subtitle {
                        Text(subtitle).lineLimit(1).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .id(scope)
        }
        .onAppear {
            if queue.isEmpty, app.library != nil { scope = .library }
        }
        .onChange(of: needle) { libraryResults = [] }
        .task(id: needle) {
            guard !needle.isEmpty, let library = app.library else { return }
            do {
                try await Task.sleep(for: .milliseconds(120))
                let matches = try await library.search(needle)
                if !Task.isCancelled { libraryResults = matches }
            } catch is CancellationError {
            } catch {
                app.error = error.localizedDescription
            }
        }
        .task(id: queue.items) {
            let urls = Array(Set(queue.items))
            if let library = app.library, let found = try? await library.tracks(at: urls), !Task.isCancelled {
                queueMetadata = Dictionary(uniqueKeysWithValues: found.map { ($0.key, QueueEntry($0.value, url: $0.key)) })
            }
            let external = urls.filter { queueMetadata[$0] == nil && app.upNextEntries[$0] == nil }
            for start in stride(from: 0, to: external.count, by: 64) {
                guard !Task.isCancelled else { break }
                let batch = Array(external[start..<min(start + 64, external.count)])
                let entries = await QueueEntry.load(batch, from: nil)
                if !Task.isCancelled { queueMetadata.merge(entries, uniquingKeysWith: { _, new in new }) }
            }
        }
    }

    private func queueResults(_ queue: PlayQueue<URL>, matching needle: String) -> [Result] {
        var results: [Result] = []
        for item in queue.order {
            let url = queue.items[item]
            let entry = queueMetadata[url] ?? app.upNextEntries[url] ?? QueueEntry(fileName: url)
            if needle.isEmpty || [entry.title, entry.subtitle ?? "", url.lastPathComponent]
                .contains(where: { $0.localizedStandardContains(needle) }) {
                results.append(Result(id: .queue(item), entry: entry))
                if results.count == 300 { break }
            }
        }
        return results
    }
}

private struct KeyboardPicker<Row: Identifiable, RowLabel: View>: View {
    let title: String
    let prompt: String
    @Binding var query: String
    let rows: [Row]
    let choose: (Row) -> Void
    @ViewBuilder let label: (Row) -> RowLabel
    @State private var selection: Row.ID?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            PickerSearchField(prompt: prompt, query: $query, move: move, submit: commit, cancel: { dismiss() })
                .frame(height: 24)
            ScrollViewReader { proxy in
                List(rows, selection: $selection) { row in
                    label(row)
                        .tag(row.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { choose(row) }
                }
                .onKeyPress(.return) {
                    commit()
                    return .handled
                }
                .onChange(of: selection) {
                    if let selection { proxy.scrollTo(selection) }
                }
                .overlay {
                    if rows.isEmpty { Text("No results").foregroundStyle(.secondary).allowsHitTesting(false) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Choose", action: commit).disabled(rows.isEmpty)
            }
        }
        .padding()
        .frame(width: 540, height: 420)
        .onChange(of: rows.map(\.id), initial: true) {
            if !rows.contains(where: { $0.id == selection }) { selection = rows.first?.id }
        }
    }

    private func move(by step: Int) {
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == selection } ?? -1
        selection = rows[min(max(index + step, 0), rows.count - 1)].id
    }

    private func commit() {
        if let row = rows.first(where: { $0.id == selection }) ?? rows.first { choose(row) }
    }
}

/// The search field's text editor owns text entry and hands list navigation to the picker.
private struct PickerSearchField: NSViewRepresentable {
    let prompt: String
    @Binding var query: String
    let move: (Int) -> Void
    let submit: () -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSearchField {
        let field = SearchField()
        field.placeholderString = prompt
        field.setAccessibilityLabel(prompt)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != query { field.stringValue = query }
        context.coordinator.field = self
    }

    private final class SearchField: NSSearchField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.initialFirstResponder = self
            window.makeFirstResponder(self)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var field: PickerSearchField?

        func controlTextDidChange(_ notification: Notification) {
            if let search = notification.object as? NSSearchField { field?.query = search.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch command {
            case #selector(NSResponder.moveDown(_:)): field?.move(1)
            case #selector(NSResponder.moveUp(_:)): field?.move(-1)
            case #selector(NSResponder.insertNewline(_:)): field?.submit()
            case #selector(NSResponder.cancelOperation(_:)): field?.cancel()
            default: return false
            }
            return true
        }
    }
}

struct JumpTimeView: View {
    let app: AppState
    @State private var time = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Jump to Time").font(.headline)
            TextField("Seconds or minutes:seconds", text: $time)
                .focused($focused)
                .onSubmit(jump)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Jump", action: jump).keyboardShortcut(.defaultAction).disabled(seconds == nil)
            }
        }
        .padding()
        .frame(width: 320)
        .onAppear { focused = true }
    }

    private var seconds: Double? {
        let parts = time.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        let values = parts.compactMap { Double($0) }
        guard values.count == parts.count, (1...3).contains(values.count),
              values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              values.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        let total = values.reduce(0) { $0 * 60 + $1 }
        return total <= app.player.duration.seconds ? total : nil
    }

    private func jump() {
        guard let seconds else { return }
        app.player.seek(to: .seconds(seconds))
        dismiss()
    }
}

struct ShortcutHelp: View {
    let app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading) {
            Text("Keyboard Shortcuts").font(.headline)
            List {
                ForEach(AppAction.allCases) { action in
                    let keys = action.keys(classic: app.winampShortcuts)
                    if !keys.isEmpty { LabeledContent(action.rawValue, value: keys) }
                }
                if app.winampShortcuts {
                    Section("Numeric Keypad") {
                        LabeledContent("Previous / Play / Next", value: "4 / 5 / 6")
                        LabeledContent("Seek back / forward", value: "7 / 9")
                        LabeledContent("Volume up / down", value: "8 / 2")
                        LabeledContent("Open files / Jump to song", value: "0 / Decimal")
                    }
                }
                Section("Search and Song Lists") {
                    LabeledContent("Move from search to results", value: "Return")
                    LabeledContent("Close search", value: "Esc")
                    LabeledContent("Skip 10 seconds", value: "⌥⌘← / →")
                    LabeledContent("Play selection · list", value: "Return")
                    LabeledContent("Play Next / Play Last · songs", value: "⌥Return / ⇧⌥Return")
                    LabeledContent("Get Info · songs", value: "⌘I")
                    LabeledContent("Remove selection · queue or playlist", value: "Delete")
                    LabeledContent("Move selection · queue or playlist order", value: "⌥↑ / ↓")
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 520, height: 560)
    }
}

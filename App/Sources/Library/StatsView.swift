import Charts
import MiniAmpKit
import SwiftUI

/// Listening stats from the play history: a year's recap, or all time.
struct StatsView: View {
    let app: AppState
    let library: Library

    enum Period: Hashable {
        case allTime
        case year(Int)
        var year: Int? { if case .year(let y) = self { y } else { nil } }
    }

    @State private var period = Period.year(Calendar.current.component(.year, from: Date()))
    @State private var years: [Int] = []
    @State private var stats: ListeningStats?
    @State private var error: String?

    private struct LoadKey: Equatable {
        var period: Period
        /// Plays are recorded as tracks play, and tracks come and go with the library.
        var trackStarts: Int
        var revision: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            // Lined up with the page below, centred in a wide window.
            PageHeader(title: "Listening Stats") {
                PeriodControl(period: $period, years: yearChoices)
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
            content
        }
        .navigationTitle("Listening Stats")
        .task(id: LoadKey(period: period, trackStarts: app.player.trackStarts, revision: library.revision)) {
            await load()
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if let stats, !stats.isEmpty {
                ScrollView {
                    StatsContent(app: app, library: library, stats: stats)
                        .padding(.horizontal, 24)
                        .padding(.top, 4)
                        .padding(.bottom, 24)
                        .frame(maxWidth: 980)
                        .frame(maxWidth: .infinity)
                }
            } else if let error {
                ContentUnavailableView("Couldn't read the play history", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if stats != nil {
                ContentUnavailableView("No Listening Yet", systemImage: "chart.bar.xaxis",
                                       description: Text(period == .allTime
                                                         ? "Songs played for 30 seconds or more show up here."
                                                         : "Nothing was played in \(String(period.year!))."))
            } else {
                Color.clear
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func load() async {
        do {
            let wanted = period
            let (years, stats) = try await library.database.writer.read { db in
                (try ListeningStats.years(db), try ListeningStats.compute(year: wanted.year, db))
            }
            guard !Task.isCancelled else { return }
            self.years = years
            self.stats = stats
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }

    /// Years with plays, and this year (so a new year has its, if empty, recap).
    private var yearChoices: [Int] {
        var all = Set(years)
        all.insert(Calendar.current.component(.year, from: Date()))
        if let year = period.year { all.insert(year) }
        return all.sorted(by: >)
    }
}

/// The year shown, stepped through with the arrows (older on the left), or chosen from the
/// menu between them, which also has All Time.
private struct PeriodControl: View {
    @Binding var period: StatsView.Period
    /// Newest first.
    let years: [Int]

    var body: some View {
        let index = period.year.flatMap { years.firstIndex(of: $0) }
        ControlGroup {
            Button { step(to: index.map { $0 + 1 }) } label: { Label("Previous Year", systemImage: "chevron.left") }
                .disabled(index.map { $0 + 1 >= years.count } ?? true)
                .help(index.flatMap { years.indices.contains($0 + 1) ? "Show \(String(years[$0 + 1]))" : nil } ?? "Previous year")
            Menu {
                Picker("Period", selection: $period) {
                    Text("All Time").tag(StatsView.Period.allTime)
                    Divider()
                    ForEach(years, id: \.self) { Text(String($0)).tag(StatsView.Period.year($0)) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(period.year.map { String($0) } ?? "All Time")
                    .monospacedDigit()
                    .frame(minWidth: 64)
            }
            .help("Show a year, or all time")
            Button { step(to: index.map { $0 - 1 }) } label: { Label("Next Year", systemImage: "chevron.right") }
                .disabled(index.map { $0 == 0 } ?? true)
                .help(index.flatMap { $0 > 0 ? "Show \(String(years[$0 - 1]))" : nil } ?? "Next year")
        }
        .controlGroupStyle(.navigation)
    }

    private func step(to index: Int?) {
        guard let index, years.indices.contains(index) else { return }
        period = .year(years[index])
    }
}

private struct StatsContent: View {
    let app: AppState
    let library: Library
    let stats: ListeningStats

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            headline
            tiles
            ChartSection(title: stats.year == nil ? "Listening by year" : "Listening by month") {
                TimelineChart(stats: stats)
            }
            HStack(alignment: .top, spacing: 24) {
                ChartSection(title: "Time of day") { HourChart(byHour: stats.byHour) }
                ChartSection(title: "Day of the week") { WeekdayChart(byWeekday: stats.byWeekday) }
            }
            HStack(alignment: .top, spacing: 24) {
                ChartSection(title: "Top songs") { TopSongs(app: app, library: library, ranked: stats.topTracks) }
                ChartSection(title: "Top artists") { RankedList(ranked: stats.topArtists, name: { $0 }) }
            }
            if !stats.topAlbums.isEmpty {
                ChartSection(title: "Top albums") { TopAlbums(library: library, ranked: stats.topAlbums) }
            }
            if !stats.topGenres.isEmpty {
                ChartSection(title: "Top genres") { RankedList(ranked: stats.topGenres, name: { $0 }) }
                    .frame(maxWidth: 460, alignment: .leading)
            }
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(stats.year.map { "In \(String($0)), you listened for \(Listening.long(stats.listened))." }
                 ?? "You've listened for \(Listening.long(stats.listened)).")
                .font(.title2.bold())
            Group {
                if let top = stats.topArtists.first, let song = stats.topTracks.first {
                    Text("Mostly \(top.item), and \(song.item.track.title) more than any other song.")
                }
                if let day = stats.busiestDay {
                    Text("Your biggest day was \(day.start.formatted(date: .long, time: .omitted)): \(Listening.long(day.listened)).")
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private var tiles: some View {
        HStack(spacing: 12) {
            StatTile(value: Listening.short(stats.listened), label: "Listening")
            StatTile(value: stats.plays.formatted(), label: stats.plays == 1 ? "Play" : "Plays")
            StatTile(value: stats.tracks.formatted(), label: stats.tracks == 1 ? "Song" : "Songs")
            StatTile(value: stats.artists.formatted(), label: stats.artists == 1 ? "Artist" : "Artists")
            if let new = stats.newArtists {
                StatTile(value: new.formatted(), label: new == 1 ? "New artist" : "New artists")
                    .help("Artists first played this year")
            }
            StatTile(value: stats.longestStreak.formatted(), label: "Day streak")
                .help("The most days in a row with something played")
        }
    }
}

// MARK: - Pieces

enum Listening {
    /// "3 hr, 20 min".
    static func long(_ duration: Duration) -> String {
        duration < .seconds(60)
            ? duration.formatted(.units(allowed: [.seconds], width: .wide))
            : duration.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    /// "120 h" or "45 min", for a tile.
    static func short(_ duration: Duration) -> String {
        duration >= .seconds(3600)
            ? "\(duration.components.seconds / 3600) h"
            : "\(duration.components.seconds / 60) min"
    }

    /// Hours when there's a lot, minutes otherwise; the chart's unit.
    static func unit(for values: [Duration]) -> (label: String, value: (Duration) -> Double) {
        (values.max() ?? .zero) >= .seconds(2 * 3600)
            ? ("Hours", { Double($0.components.seconds) / 3600 })
            : ("Minutes", { Double($0.components.seconds) / 60 })
    }
}

private struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.bold().monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.callout).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ChartSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A bar's top corners rounded, its base square on the axis.
private let barShape = UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)

/// The hover readout over a bar.
private struct Tooltip: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.bold().monospacedDigit())
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
    }
}

private struct TimelineChart: View {
    let stats: ListeningStats
    @State private var selected: Date?

    var body: some View {
        let byYear = stats.year == nil
        let unit = Listening.unit(for: stats.timeline.map(\.listened))
        let hovered = selected.flatMap { date in
            stats.timeline.first { Calendar.current.isDate($0.start, equalTo: date, toGranularity: byYear ? .year : .month) }
        }
        Chart {
            ForEach(stats.timeline) { bucket in
                BarMark(x: .value(byYear ? "Year" : "Month", bucket.start, unit: byYear ? .year : .month),
                        y: .value(unit.label, unit.value(bucket.listened)), width: .ratio(0.6))
                    .clipShape(barShape)
                    .foregroundStyle(Color.accentColor.opacity(hovered == nil || hovered?.start == bucket.start ? 1 : 0.45))
            }
            if let hovered {
                RuleMark(x: .value("Selected", hovered.start, unit: byYear ? .year : .month))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Tooltip(title: hovered.start.formatted(byYear ? .dateTime.year() : .dateTime.month(.wide).year()),
                                value: "\(Listening.long(hovered.listened)) · \(hovered.plays) play\(hovered.plays == 1 ? "" : "s")")
                    }
            }
        }
        .chartXSelection(value: $selected)
        .chartXAxis {
            AxisMarks(values: .stride(by: byYear ? .year : .month)) { _ in
                AxisValueLabel(format: byYear ? .dateTime.year() : .dateTime.month(.abbreviated), centered: true)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel()
            }
        }
        .chartYAxisLabel(unit.label)
        .frame(height: 200)
    }
}

private struct HourChart: View {
    let byHour: [Duration]
    @State private var selected: Int?

    var body: some View {
        let unit = Listening.unit(for: byHour)
        Chart {
            ForEach(0..<24, id: \.self) { hour in
                BarMark(x: .value("Hour", hour), y: .value(unit.label, unit.value(byHour[hour])), width: .ratio(0.7))
                    .clipShape(barShape)
                    .foregroundStyle(Color.accentColor.opacity(selected == nil || selected == hour ? 1 : 0.45))
            }
            if let selected, (0..<24).contains(selected) {
                RuleMark(x: .value("Selected", selected))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Tooltip(title: "\(Self.label(selected))–\(Self.label((selected + 1) % 24))",
                                value: Listening.long(byHour[selected]))
                    }
            }
        }
        .chartXSelection(value: $selected)
        .chartXScale(domain: -0.5...23.5)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18]) { value in
                AxisValueLabel { if let hour = value.as(Int.self) { Text(Self.label(hour)) } }
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel()
            }
        }
        .chartYAxisLabel(unit.label)
        .frame(height: 160)
    }

    /// "6 AM" or "06", as the locale writes hours.
    static func label(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }
}

private struct WeekdayChart: View {
    let byWeekday: [Duration]
    @State private var selected: String?

    var body: some View {
        let calendar = Calendar.current
        // byWeekday is Sunday-first; show the week as the locale starts it.
        let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 }
        let names = calendar.shortWeekdaySymbols
        let unit = Listening.unit(for: byWeekday)
        Chart {
            ForEach(order, id: \.self) { day in
                BarMark(x: .value("Day", names[day]), y: .value(unit.label, unit.value(byWeekday[day])), width: .ratio(0.6))
                    .clipShape(barShape)
                    .foregroundStyle(Color.accentColor.opacity(selected == nil || selected == names[day] ? 1 : 0.45))
            }
            if let selected, let day = names.firstIndex(of: selected) {
                RuleMark(x: .value("Selected", selected))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Tooltip(title: calendar.weekdaySymbols[day], value: Listening.long(byWeekday[day]))
                    }
            }
        }
        .chartXSelection(value: $selected)
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel()
            }
        }
        .chartYAxisLabel(unit.label)
        .frame(height: 160)
    }
}

/// Ranked names with a bar for their plays.
private struct RankedList<Item: Sendable & Equatable>: View {
    let ranked: [ListeningStats.Ranked<Item>]
    let name: (Item) -> String

    var body: some View {
        let most = max(ranked.first?.plays ?? 1, 1)
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            ForEach(Array(ranked.enumerated()), id: \.offset) { index, entry in
                GridRow {
                    Text("\(index + 1)").foregroundStyle(.secondary).monospacedDigit().gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name(entry.item)).lineLimit(1)
                        GeometryReader { geometry in
                            Capsule().fill(Color.accentColor)
                                .frame(width: max(4, geometry.size.width * CGFloat(entry.plays) / CGFloat(most)), height: 4)
                        }
                        .frame(height: 4)
                    }
                    Text("\(entry.plays)").foregroundStyle(.secondary).monospacedDigit().gridColumnAlignment(.trailing)
                        .help(Listening.long(entry.listened))
                }
            }
        }
    }
}

private struct TopSongs: View {
    let app: AppState
    let library: Library
    let ranked: [ListeningStats.Ranked<TrackInfo>]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(ranked.enumerated()), id: \.offset) { index, entry in
                HStack(spacing: 10) {
                    Text("\(index + 1)").foregroundStyle(.secondary).monospacedDigit().frame(width: 20, alignment: .trailing)
                    ArtworkView(key: entry.item.track.artworkKey, artwork: library.artwork, size: .small)
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.item.track.title).lineLimit(1)
                        Text(entry.item.artistName ?? "Unknown Artist").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text("\(entry.plays)").foregroundStyle(.secondary).monospacedDigit()
                        .help("\(entry.plays) play\(entry.plays == 1 ? "" : "s"), \(Listening.long(entry.listened))")
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { app.play(ranked.map(\.item), from: entry.item.id) }
                .help("Double-click to play the top songs from here")
            }
        }
    }
}

private struct TopAlbums: View {
    let library: Library
    let ranked: [ListeningStats.Ranked<ListeningStats.AlbumItem>]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 16, alignment: .top)],
                  alignment: .leading, spacing: 16) {
            ForEach(ranked, id: \.item.id) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    ArtworkView(key: entry.item.artworkKey, artwork: library.artwork, size: .small, cornerRadius: 6)
                    Text(entry.item.title).font(.callout).lineLimit(1)
                    Text("\(entry.item.artist ?? "Unknown Artist") · \(entry.plays) play\(entry.plays == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

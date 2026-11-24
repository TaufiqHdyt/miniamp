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
        var playHistoryRevision: Int
    }

    var body: some View {
        content
            .pageTitle("Listening Stats") { PeriodControl(period: $period, years: yearChoices) }
        .task(id: LoadKey(period: period, trackStarts: app.player.trackStarts, revision: library.revision,
                          playHistoryRevision: app.playHistoryRevision)) {
            await load()
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if let stats, !stats.isEmpty {
                ScrollView {
                    StatsContent(app: app, library: library, stats: stats)
                        .padding(.horizontal, Theme.Spacing.page)
                        .padding(.top, Theme.Spacing.m)
                        .padding(.bottom, Theme.Spacing.l)
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
        .environment(\.statsChartColor, app.tint ?? .accentColor)
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
    @State private var width: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            headline
            tiles
            ChartSection(title: stats.year == nil ? "Listening by year" : "Listening by month") {
                TimelineChart(stats: stats)
            }
            pairedSections {
                ChartSection(title: "Time of day") { HourChart(byHour: stats.byHour) }
                ChartSection(title: "Day of the week") { WeekdayChart(byWeekday: stats.byWeekday) }
            }
            if !stats.topTracks.isEmpty {
                Shelf(title: "Top songs", contents: stats.topTracks.map { AnyHashable($0.item.id) }) {
                    ForEach(stats.topTracks, id: \.item.id) { entry in
                        let card = rankCard(entry.item.track.title, subtitle: entry.item.artistName,
                                            artworkKey: entry.item.track.artworkKey, plays: entry.plays, listened: entry.listened)
                        if let id = entry.item.track.id, id > 0 {
                            Button {
                                let playable = stats.topTracks.map(\.item).filter { ($0.track.id ?? 0) > 0 }
                                app.play(playable, from: entry.item.id)
                            } label: { card }
                            .buttonStyle(.plain)
                            .accessibilityHint("Plays the top songs from here")
                        } else {
                            card
                        }
                    }
                }
            }
            if !stats.topArtists.isEmpty {
                Shelf(title: "Top artists", contents: stats.topArtists.map { AnyHashable($0.item) }) {
                    ForEach(stats.topArtists, id: \.item) { entry in
                        rankCard(entry.item, plays: entry.plays, listened: entry.listened, symbol: "person")
                    }
                }
            }
            if !stats.topAlbums.isEmpty {
                Shelf(title: "Top albums", contents: stats.topAlbums.map { AnyHashable($0.item.id) }) {
                    ForEach(stats.topAlbums, id: \.item.id) { entry in
                        let card = rankCard(entry.item.title, subtitle: entry.item.artist,
                                            artworkKey: entry.item.artworkKey, plays: entry.plays, listened: entry.listened)
                        if entry.item.isInLibrary {
                            NavigationLink(value: LibraryDestination.album(entry.item.id)) { card }
                                .buttonStyle(.plain)
                        } else {
                            card
                        }
                    }
                }
            }
            if !stats.topGenres.isEmpty {
                Shelf(title: "Top genres", contents: stats.topGenres.map { AnyHashable($0.item) }) {
                    ForEach(stats.topGenres, id: \.item) { entry in
                        rankCard(entry.item, plays: entry.plays, listened: entry.listened, symbol: "music.note")
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func rankCard(_ title: String, subtitle: String? = nil, artworkKey: String? = nil,
                          plays: Int, listened: Duration, symbol: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.largeTitle)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
                } else {
                    ArtworkView(key: artworkKey, artwork: library.artwork, size: .small,
                                cornerRadius: Theme.Radius.medium)
                }
            }
            .frame(width: 128, height: 128)
            .accessibilityHidden(true)
            Text(title).font(.callout.weight(.semibold)).lineLimit(1)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Text(plays == 1 ? "1 play" : "\(plays) plays").font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 128, alignment: .leading)
        .accessibilityElement(children: .combine)
        .help(Listening.long(listened))
    }

    private func pairedSections(@ViewBuilder content: () -> some View) -> some View {
        let layout = width >= 620
            ? AnyLayout(HStackLayout(alignment: .top, spacing: Theme.Spacing.m))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Spacing.l))
        return layout { content() }
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: Theme.Spacing.s)],
                  spacing: Theme.Spacing.s) {
            StatCard(value: Listening.short(stats.listened), label: "Listening")
            StatCard(value: stats.plays.formatted(), label: stats.plays == 1 ? "Play" : "Plays")
            StatCard(value: stats.tracks.formatted(), label: stats.tracks == 1 ? "Song" : "Songs")
            StatCard(value: stats.artists.formatted(), label: stats.artists == 1 ? "Artist" : "Artists")
            if let new = stats.newArtists {
                StatCard(value: new.formatted(), label: new == 1 ? "New artist" : "New artists")
                    .help("Artists first played this year")
            }
            StatCard(value: stats.longestStreak.formatted(), label: "Day streak")
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

    /// "15.6 h", "120 h" or "45 min", for a tile: tenths of an hour below 100, so it agrees
    /// with `long` beside it ("15 hr, 34 min"), where whole hours would round to 16.
    static func short(_ duration: Duration) -> String {
        let minutes = (duration.components.seconds + 30) / 60
        guard minutes >= 60 else { return "\(minutes) min" }
        let tenths = (minutes * 10 + 30) / 60
        if tenths >= 1000 { return "\((tenths + 5) / 10) h" }
        return tenths % 10 == 0 ? "\(tenths / 10) h" : (Double(tenths) / 10).formatted(.number.precision(.fractionLength(1))) + " h"
    }

    /// Hours when there's a lot, minutes otherwise; the chart's unit.
    static func unit(for values: [Duration]) -> (label: String, value: (Duration) -> Double) {
        (values.max() ?? .zero) >= .seconds(2 * 3600)
            ? ("Hours", { Double($0.components.seconds) / 3600 })
            : ("Minutes", { Double($0.components.seconds) / 60 })
    }
}

private struct ChartSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.l)
        .panelSurface()
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .elevation(.card)
    }
}

private struct TimelineChart: View {
    let stats: ListeningStats
    @State private var selected: Date?

    @Environment(\.statsChartColor) private var chartColor

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
                    .foregroundStyle(chartColor.opacity(hovered == nil || hovered?.start == bucket.start ? 1 : 0.45))
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
    @State private var selectedX: Double?

    /// The hour under the pointer.
    private var selected: Int? { selectedX.map { min(max(Int($0.rounded()), 0), 23) } }

    @Environment(\.statsChartColor) private var chartColor

    var body: some View {
        let unit = Listening.unit(for: byHour)
        let played = (0..<24).filter { byHour[$0] > .zero }
        Chart {
            // Each bar spans its hour by hand: on a numeric axis, BarMark's ratio width drew
            // no bars at all.
            ForEach(played, id: \.self) { hour in
                bar(hour, unit: unit)
            }
            if let selected {
                RuleMark(x: .value("Selected", Double(selected)))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Tooltip(title: "\(Self.label(selected))–\(Self.label((selected + 1) % 24))",
                                value: Listening.long(byHour[selected]))
                    }
            }
        }
        .chartXSelection(value: $selectedX)
        .chartXScale(domain: -0.5...23.5)
        .chartXAxis {
            AxisMarks(values: [0.0, 6, 12, 18]) { value in
                AxisValueLabel { if let hour = value.as(Double.self) { Text(Self.label(Int(hour))) } }
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

    private func bar(_ hour: Int, unit: (label: String, value: (Duration) -> Double)) -> some ChartContent {
        let x = Double(hour)
        let start: Double = x - 0.35
        let end: Double = x + 0.35
        let value: Double = unit.value(byHour[hour])
        return RectangleMark(xStart: .value("Hour", start), xEnd: .value("Hour", end),
                             yStart: .value(unit.label, 0.0), yEnd: .value(unit.label, value))
            .clipShape(barShape)
            .foregroundStyle(chartColor.opacity(selected == nil || selected == hour ? 1 : 0.45))
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

    @Environment(\.statsChartColor) private var chartColor

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
                    .foregroundStyle(chartColor.opacity(selected == nil || selected == names[day] ? 1 : 0.45))
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
private extension EnvironmentValues {
    @Entry var statsChartColor: Color = .accentColor
}

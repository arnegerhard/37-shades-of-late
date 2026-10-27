import SwiftUI
import WidgetKit

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> DeparturesEntry { .sample() }

    func getSnapshot(in context: Context, completion: @escaping (DeparturesEntry) -> Void) {
        if context.isPreview { return completion(.sample()) }
        Task { completion(await load().first ?? .sample()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DeparturesEntry>) -> Void) {
        Task {
            let entries = await load()
            // Ask for fresh live data in 5 minutes; iOS may stretch this to save battery. After a failed
            // fetch, try again in a minute.
            let failed = entries.first?.rows.contains(where: \.stale) ?? false
            completion(Timeline(entries: entries, policy: .after(.now + (failed ? 60 : 5 * 60))))
        }
    }

    /// The stop open in the app first (it's what the Lock Screen's single-line and round widgets
    /// show), then the other favorites in their saved order. Fetched together, then an entry per
    /// minute so the minutes count down between refreshes.
    private func load() async -> [DeparturesEntry] {
        let now = Date.now
        let selections = Array(Selection.widgetSelections.prefix(4))
        let rows = await withTaskGroup(of: (Int, WidgetRow).self) { group in
            for (index, selection) in selections.enumerated() {
                group.addTask {
                    do {
                        let departures = try await TransitService.departures(for: selection, client: .widget)
                        return (index, WidgetRow(selection: selection, departures: departures))
                    } catch {
                        // Show the times the app (or an earlier widget update) last saw, rather than a dash.
                        if let lastKnown = TransitService.lastKnownDepartures(for: selection) {
                            return (index, WidgetRow(selection: selection, departures: lastKnown, stale: true))
                        }
                        return (index, WidgetRow(selection: selection, departures: [], failed: true, stale: true))
                    }
                }
            }
            var rows = [(Int, WidgetRow)]()
            for await row in group { rows.append(row) }
            return rows.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let error = rows.allSatisfy(\.failed) ? "Departures are late too" : nil
        return (0..<15).map { DeparturesEntry(date: now + Double($0) * 60, rows: rows, error: error) }
    }
}

/// Reads the family from the widget environment and hands it to the shared views.
struct WidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DeparturesEntry

    var body: some View { Bus37WidgetView(entry: entry, family: family) }
}

struct Bus37Widget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Bus37Widget", provider: Provider()) { entry in
            WidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Favorites")
        .description("Minutes until your favorites show up, in the order you arranged them. Be let down without unlocking.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

@main
struct Bus37WidgetBundle: WidgetBundle {
    var body: some Widget { Bus37Widget() }
}

#Preview(as: .systemSmall) {
    Bus37Widget()
} timeline: {
    DeparturesEntry.sample()
}

#Preview(as: .accessoryRectangular) {
    Bus37Widget()
} timeline: {
    DeparturesEntry.sample()
}

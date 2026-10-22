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
            // Ask for fresh live data in 5 minutes; iOS may stretch this to save battery.
            completion(Timeline(entries: entries, policy: .after(.now + 5 * 60)))
        }
    }

    /// The favorites in their saved order (or the app's current stop if none are saved), fetched
    /// together, then an entry per minute so the minutes count down between refreshes.
    private func load() async -> [DeparturesEntry] {
        let now = Date.now
        let favorites = Selection.favorites
        let selections = Array((favorites.isEmpty ? [Selection.current] : favorites).prefix(4))
        let rows = await withTaskGroup(of: (Int, WidgetRow).self) { group in
            for (index, selection) in selections.enumerated() {
                group.addTask {
                    do {
                        let departures = try await TransitService.departures(for: selection, client: .widget)
                        return (index, WidgetRow(selection: selection, departures: departures))
                    } catch {
                        return (index, WidgetRow(selection: selection, departures: [], failed: true))
                    }
                }
            }
            var rows = [(Int, WidgetRow)]()
            for await row in group { rows.append(row) }
            return rows.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let error = rows.allSatisfy(\.failed) ? "Couldn't load departures" : nil
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
        .description("Minutes until the next departures for your favorites, in the order you arranged them in the app.")
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

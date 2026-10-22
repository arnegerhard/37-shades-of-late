import SwiftUI
import WidgetKit

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> DeparturesEntry {
        .init(date: .now, departures: [5, 17, 29].map { Departure(time: .now + $0 * 60, isLive: true) }, error: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (DeparturesEntry) -> Void) {
        if context.isPreview { return completion(placeholder(in: context)) }
        Task { completion(await load().first ?? placeholder(in: context)) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DeparturesEntry>) -> Void) {
        Task {
            let entries = await load()
            // Ask for fresh live data in 5 minutes; iOS may stretch this to save battery.
            completion(Timeline(entries: entries, policy: .after(.now + 5 * 60)))
        }
    }

    /// One fetch, then an entry per minute so "in N min" counts down between refreshes.
    private func load() async -> [DeparturesEntry] {
        let now = Date.now
        do {
            let departures = try await TransitService.departures(client: .widget)
            return (0..<15).map { DeparturesEntry(date: now + Double($0) * 60, departures: departures, error: nil) }
        } catch {
            return [DeparturesEntry(date: now, departures: [], error: error.localizedDescription)]
        }
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
        .configurationDisplayName("Next Departures")
        .description("Upcoming departures for the line and stop you picked in the app.")
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
    DeparturesEntry(date: .now, departures: [4, 16, 31].map { Departure(time: .now + $0 * 60, isLive: true) }, error: nil)
}

#Preview(as: .accessoryRectangular) {
    Bus37Widget()
} timeline: {
    DeparturesEntry(date: .now, departures: [4, 16, 31].map { Departure(time: .now + $0 * 60, isLive: true) }, error: nil)
}

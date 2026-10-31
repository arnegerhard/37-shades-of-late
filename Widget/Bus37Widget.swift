import SwiftUI
import WidgetKit

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> DeparturesEntry { .sample() }

    func getSnapshot(in context: Context, completion: @escaping (DeparturesEntry) -> Void) {
        if context.isPreview { return completion(.sample()) }
        Task { completion(await load(for: context.family).first ?? .sample()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DeparturesEntry>) -> Void) {
        Task {
            let entries = await load(for: context.family)
            // Ask for fresh live data in 5 minutes; iOS may stretch this to save battery. After a failed
            // fetch, try again in a minute. Asleep, there's nothing to fetch: just whether it's time to
            // wake up, every 20 minutes (as often as the place is asked).
            let failed = entries.first?.rows.contains(where: \.stale) ?? false
            let wait: TimeInterval = entries.first?.awayFrom != nil ? 20 * 60 : failed ? 60 : 5 * 60
            completion(Timeline(entries: entries, policy: .after(.now + wait)))
        }
    }

    /// The favorites of the city you're in, in their saved order. Fetched together, then an entry
    /// per minute so the minutes count down between refreshes. Far from every city, the Lock Screen
    /// widgets sleep, fetching nothing, and the Home Screen's show home's (the city with the most
    /// favorites).
    private func load(for family: WidgetFamily) async -> [DeparturesEntry] {
        let now = Date.now
        let place = await TransitService.widgetPlace()
        if place.isAway, [.accessoryInline, .accessoryCircular, .accessoryRectangular].contains(family) {
            // An entry a minute, on the minute, for home's clock.
            let minute = (now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60
            return (0..<30).map { DeparturesEntry(date: Date(timeIntervalSinceReferenceDate: minute + Double($0) * 60),
                                                 rows: [], error: nil, awayFrom: Selection.homeCity) }
        }
        let selections = Array(Selection.widgetSelections(near: place.isAway ? Selection.homeCity : place.city).prefix(4))
        let client: Client = [.accessoryInline, .accessoryCircular, .accessoryRectangular].contains(family) ? .lockscreen : .widget
        let rows = await withTaskGroup(of: (Int, WidgetRow).self) { group in
            for (index, selection) in selections.enumerated() {
                group.addTask {
                    do {
                        let departures = try await TransitService.departures(for: selection, client: client)
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

/// A watched stop on the Dynamic Island and the Lock Screen (see BusActivity.swift).
struct BusActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BusActivity.self) { context in
            BusActivityView(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(context.attributes.link.tapped(on: "activity"))
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    // Clear of the island's rounded ends.
                    BusActivityView(attributes: context.attributes, state: state, isStale: context.isStale)
                        .padding(.horizontal, 10)
                }
            } compactLeading: {
                // Shrinks rather than cutting "131" down to "13…".
                LineBadges(parts: context.attributes.badgeParts, font: .system(.caption, design: .rounded).weight(.heavy),
                           round: context.attributes.round ?? false)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } compactTrailing: {
                // A fixed width, its digits against the right end: a timer is laid out as wide as its widest
                // value, and left to itself it pushed the badge into "13…" and its own digits out of sight.
                // Wide enough for two-digit minutes, which a 42-point width cut short as "12:…".
                Group {
                    if context.isStale {
                        Text("gone")
                    } else {
                        Countdown(date: state.next, from: context.attributes.startedAt)
                            .foregroundStyle(state.nextIsLive ? .green : .secondary)
                    }
                }
                // A fixed size, not one that grows with the text size setting: "12:34" has to fit as well as "4:12".
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .multilineTextAlignment(.trailing)
                .frame(width: 50, alignment: .trailing)
            } minimal: {
                // Sharing the island with another app's activity: what matters from the train is how long
                // there is, so the minutes, green when the bus is on the map. Which bus it is, they know.
                if context.isStale {
                    Image(systemName: "checkmark")
                } else {
                    MinutesLeft(date: state.next, from: context.attributes.startedAt)
                        .foregroundStyle(state.nextIsLive ? .green : .white)
                }
            }
            .widgetURL(context.attributes.link.tapped(on: "island"))
            .keylineTint(LineBadge.red)
        }
    }
}

@main
struct Bus37WidgetBundle: WidgetBundle {
    var body: some Widget {
        Bus37Widget()
        BusActivityWidget()
    }
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
    DeparturesEntry.sampleAsleep
}

#Preview(as: .accessoryCircular) {
    Bus37Widget()
} timeline: {
    DeparturesEntry.sampleAsleep
}

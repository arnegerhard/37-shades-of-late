import AppIntents
import SwiftUI
import WidgetKit

// Widget views live here so the app can render them too (see Screenshots.swift).

struct DeparturesEntry: TimelineEntry {
    let date: Date
    let departures: [Departure]
    let error: String?
    var selection: Selection = .current

    var upcoming: [Departure] { departures.filter { $0.time > date.addingTimeInterval(-30) } }
}

struct RefreshIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh departures"
    func perform() async throws -> some IntentResult { .result() }
}

struct Bus37WidgetView: View {
    let entry: DeparturesEntry
    let family: WidgetFamily

    private var maxRows: Int { family == .systemSmall ? 3 : 4 }

    var body: some View {
        switch family {
        case .accessoryRectangular, .accessoryCircular, .accessoryInline:
            LockScreenView(entry: entry, family: family)
        default:
            homeScreen
        }
    }

    private var homeScreen: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let error = entry.error {
                Spacer()
                Text(error).font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else if entry.upcoming.isEmpty {
                Spacer()
                Text("No \(entry.selection.lineID)s scheduled").font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(entry.upcoming.prefix(maxRows), id: \.self) { row($0) }
                Spacer(minLength: 0)
            }
        }
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }

    private var header: some View {
        HStack(spacing: 6) {
            LineBadge(line: entry.selection.lineID)
            VStack(alignment: .leading, spacing: 0) {
                Text("To \(entry.selection.destination)").font(.caption.weight(.semibold))
                Text(entry.selection.stopName).font(.caption2).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            Button(intent: RefreshIntent()) {
                Image(systemName: "arrow.clockwise").font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private func row(_ departure: Departure) -> some View {
        let minutes = max(0, Int(departure.time.timeIntervalSince(entry.date) / 60))
        return HStack(alignment: .firstTextBaseline) {
            Text(departure.time, format: .dateTime.hour().minute())
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Spacer(minLength: 4)
            Text(minutes == 0 ? "now" : "\(minutes) min")
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(departure.isLive ? .green : .secondary)
        }
    }
}

/// Lock Screen layouts. iOS tints these monochrome, so they rely on weight and layout, not color.
struct LockScreenView: View {
    let entry: DeparturesEntry
    let family: WidgetFamily

    private var next: [Departure] { Array(entry.upcoming.prefix(3)) }

    private func minutes(until departure: Departure) -> Int {
        max(0, Int(departure.time.timeIntervalSince(entry.date) / 60))
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: circular
            case .accessoryInline: inline
            default: rectangular
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: "bus.fill")
                Text("\(entry.selection.lineID) to \(entry.selection.destination)")
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .font(.headline)
            .widgetAccentable()
            if next.isEmpty {
                Text(entry.error ?? "No \(entry.selection.lineID)s scheduled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(next.prefix(2), id: \.self) { departure in
                    HStack {
                        Text(departure.time, format: .dateTime.hour().minute())
                        Spacer()
                        Text(minutes(until: departure) == 0 ? "now" : "\(minutes(until: departure)) min")
                            .foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: -2) {
                Text(entry.selection.lineID)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .widgetAccentable()
                if let first = next.first {
                    Text("\(minutes(until: first))")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("min").font(.system(size: 10))
                } else {
                    Text("–").font(.system(size: 22, weight: .semibold, design: .rounded))
                }
            }
        }
    }

    @ViewBuilder private var inline: some View {
        if next.isEmpty {
            Text("\(entry.selection.lineID) · no buses")
        } else {
            Text("\(entry.selection.lineID) · " + next.map { $0.time.formatted(.dateTime.hour().minute()) }.joined(separator: ", "))
        }
    }
}

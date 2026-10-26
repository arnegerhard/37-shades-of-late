import AppIntents
import SwiftUI
import WidgetKit

// Widget views live here so the app can render them too (see Screenshots.swift).

/// One favorite and its upcoming departures.
struct WidgetRow: Hashable {
    let selection: Selection
    let departures: [Departure]
    /// Set when this favorite's times couldn't be loaded.
    var failed = false
}

/// The widgets show the favorites, in the order the user arranged them, as line names and
/// minutes until the next departures; with no favorites saved, the line and stop open in the app.
struct DeparturesEntry: TimelineEntry {
    let date: Date
    let rows: [WidgetRow]
    let error: String?

    /// Departures that haven't left yet at this entry's time.
    func upcoming(_ row: WidgetRow) -> [Departure] {
        row.departures.filter { $0.time > date.addingTimeInterval(-30) }
    }

    func minutes(until departure: Departure) -> Int {
        max(0, Int(departure.time.timeIntervalSince(date) / 60))
    }

    /// "4 · 16 · 31 min", or "now · 9 min".
    func waits(_ row: WidgetRow, count: Int, unit: Bool = true) -> String? {
        Departure.waits(upcoming(row), from: date, count: count, unit: unit)
    }

    /// With favorites from more than one city, each row is tagged with its city ("SF", "SEA"),
    /// since line numbers repeat between cities (both have an 8, a 14, a 1 Line...).
    /// Only the rows a widget actually shows count (`visible`), so a Seattle favorite further down
    /// doesn't tag an all-SF Lock Screen.
    func cityTag(for row: WidgetRow, visible: Int) -> String? {
        Set(rows.prefix(visible).map(\.selection.city)).count > 1 ? row.selection.city.code : nil
    }

    /// The same line saved twice in one city (two stops or directions) gets its destination added
    /// to tell them apart.
    func label(for row: WidgetRow) -> String? {
        rows.filter { $0.selection.lineID == row.selection.lineID && $0.selection.city == row.selection.city }.count > 1
            ? String(row.selection.destination.split(separator: " ").first ?? "")
            : nil
    }

    /// Placeholder rows for previews and the widget gallery.
    static func sample(at date: Date = .now) -> DeparturesEntry {
        let rows = [(Selection.defaultSelection, [4, 16, 31]),
                    (Selection(lineID: "N", lineName: "Judah", directionID: "OB", destination: "Ocean Beach",
                               stopCode: "14447", stopName: "Duboce Ave & Church St"), [2, 11, 20]),
                    (Selection(lineID: "22", lineName: "Fillmore", directionID: "IB", destination: "Mission Bay",
                               stopCode: "13254", stopName: "Church St & Market St"), [9, 21])]
            .map { selection, waits in
                WidgetRow(selection: selection, departures: waits.map { Departure(time: date + Double($0) * 60 + 20, isLive: true) })
            }
        return DeparturesEntry(date: date, rows: rows, error: nil)
    }
}

struct RefreshIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh departures"
    func perform() async throws -> some IntentResult { .result() }
}

struct Bus37WidgetView: View {
    let entry: DeparturesEntry
    let family: WidgetFamily

    private let maxRows = 4

    var body: some View {
        switch family {
        case .accessoryRectangular, .accessoryCircular, .accessoryInline:
            LockScreenView(entry: entry, family: family)
        default:
            homeScreen
        }
    }

    private var homeScreen: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 7 : 6) {
            if let error = entry.error, entry.rows.isEmpty {
                Spacer()
                Text(error).font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(entry.rows.prefix(maxRows), id: \.self) { row($0) }
                Spacer(minLength: 0)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Button(intent: RefreshIntent()) {
                Image(systemName: "arrow.clockwise").font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
        }
        // Four rows only fit up to "large" text; beyond that iOS would push the last one out.
        .dynamicTypeSize(...DynamicTypeSize.large)
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }

    private func row(_ row: WidgetRow) -> some View {
        let next = entry.upcoming(row).first
        let small = family == .systemSmall
        return HStack(alignment: .center, spacing: small ? 5 : 8) {
            if let tag = entry.cityTag(for: row, visible: maxRows) {
                if small {
                    // No room for the outlined tag in the small widget: a tiny code before the badge.
                    Text(tag)
                        .font(.system(size: 8, weight: .heavy, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: 19, alignment: .leading)
                } else {
                    CityTag(code: tag)
                }
            }
            // The badge always shows the whole line name ("37", "C Line"): it keeps its full width and
            // the waits shrink instead. Long names get a smaller font in the small widget.
            let longName = row.selection.lineID.count > 3
            LineBadge(line: row.selection.lineID,
                      font: .system(small ? (longName ? .caption2 : .footnote) : .subheadline, design: .rounded).weight(.heavy))
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(2)
            if !small, let label = entry.label(for: row) {
                Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 2)
            // The small widget drops "min" so two waits always fit next to the badge.
            Text(entry.waits(row, count: small ? 2 : 4, unit: !small) ?? (row.failed ? "–" : "none"))
                .font(.system(small ? .callout : .subheadline, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .layoutPriority(1)
                .foregroundStyle(next?.isLive == true ? .green : .secondary)
        }
    }
}

/// Lock Screen layouts. iOS tints these monochrome, so they rely on weight and layout, not color.
struct LockScreenView: View {
    let entry: DeparturesEntry
    let family: WidgetFamily

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
        VStack(alignment: .leading, spacing: 0) {
            if entry.rows.isEmpty {
                Text(entry.error ?? "No favorites").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(entry.rows.prefix(3), id: \.self) { row in
                HStack(spacing: 6) {
                    if let tag = entry.cityTag(for: row, visible: 3) {
                        Text(tag).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                            .frame(width: 22, alignment: .leading)
                    }
                    Text(row.selection.lineID)
                        .font(.system(.headline, design: .rounded).weight(.heavy))
                        .widgetAccentable()
                    if let label = entry.label(for: row) {
                        Text(label).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 2)
                    Text(entry.waits(row, count: 2) ?? "–")
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The first favorite only: its line and the minutes to its next departure.
    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: -2) {
                Text(entry.rows.first?.selection.lineID ?? "–")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .widgetAccentable()
                if let row = entry.rows.first, let next = entry.upcoming(row).first {
                    Text("\(entry.minutes(until: next))")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("min").font(.system(size: 10))
                } else {
                    Text("–").font(.system(size: 22, weight: .semibold, design: .rounded))
                }
            }
        }
    }

    /// "37 4m · N 2m · 22 9m": each favorite's next departure.
    private var inline: some View {
        let parts = entry.rows.prefix(3).map { row -> String in
            let name = [entry.cityTag(for: row, visible: 3), row.selection.lineID].compactMap { $0 }.joined(separator: " ")
            guard let next = entry.upcoming(row).first else { return "\(name) –" }
            let minutes = entry.minutes(until: next)
            return "\(name) \(minutes == 0 ? "now" : "\(minutes)m")"
        }
        return Text(parts.isEmpty ? "No favorites" : parts.joined(separator: " · "))
    }
}

/// A small outlined city code ("SF", "SEA") in front of a line badge, in widgets and the favorites list.
struct CityTag: View {
    let code: String

    var body: some View {
        Text(code)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(width: 24)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.6), lineWidth: 1))
    }
}

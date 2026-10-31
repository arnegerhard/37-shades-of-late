import ActivityKit
import CoreText
import SwiftUI
import WidgetKit

// A stop's next departure as a Live Activity, on the Dynamic Island and the Lock Screen, for watching
// it from another app (on the train, wondering whether the bus will wait). It lasts until the bus
// after the one being watched is due, or an hour, whichever comes first. The views count down on
// their own; the app updates the times whenever it has new ones, and the proxy pushes them otherwise.
// The Lock Screen's widget already has the minutes, so the Lock Screen's card is about what it
// doesn't: where the bus is, and how fresh that is.

struct BusActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The departure being watched.
        var next: Date
        var nextIsLive: Bool
        /// The one after it, if there is one.
        var after: Date?
        /// When the activity is over, as of these times.
        var ends: Date
        /// When these times were fetched.
        var updatedAt: Date?
        /// How many stops the watched bus still has to go to get here, when it's on the map.
        var stopsAway: Int?
    }

    /// The selection's id, to find its activity again.
    let selectionID: String
    let line: String
    let destination: String
    let stopName: String
    /// "bus", "train" or "ferry".
    let vehicle: String
    /// Opens the stop on the app's map.
    let link: URL
    let startedAt: Date
    /// A round badge (see `LineBadge.isRound`); optional, as activities started before it was have none.
    var round: Bool? = nil
    /// Its badges, in their colors (see `Selection.badgeParts`); without them, `line` in the app's red.
    var badges: [BadgePart]? = nil
    /// False for lines whose vehicles are never on the map (see `Selection.showsVehicles`); unknown in
    /// activities started before it was asked.
    var showsVehicles: Bool? = nil

    var badgeParts: [BadgePart] { badges ?? [BadgePart(label: line)] }

    static let longest: TimeInterval = 60 * 60
}

extension BusActivity.ContentState {
    /// The watched and following departures from `departures`, ending at the following one or
    /// an hour after `start`, whichever is sooner (a minute after the last one, without a following one).
    /// With `route` (the stops of the line's direction), how far the watched bus is from `stop`.
    init?(departures: [Departure], since start: Date, fetchedAt: Date, route: [Stop]? = nil, stop: String? = nil, now: Date = .now) {
        let upcoming = departures.filter { $0.time > now.addingTimeInterval(-30) }
        guard let next = upcoming.first else { return nil }
        let after = upcoming.dropFirst().first?.time
        self.init(next: next.time, nextIsLive: next.isLive, after: after,
                  ends: min(start.addingTimeInterval(BusActivity.longest), after ?? next.time.addingTimeInterval(60)),
                  updatedAt: fetchedAt,
                  stopsAway: next.vehicle.flatMap { vehicle in route.flatMap { route in stop.flatMap { Self.stops(from: vehicle, to: $0, along: route) } } })
    }

    /// Stops from the one `vehicle` is nearest (before `stop`, within 400 m) to `stop`. As in the proxy's activities.ts.
    static func stops(from vehicle: Vehicle, to stop: String, along route: [Stop]) -> Int? {
        guard let here = route.firstIndex(where: { $0.code == stop }) else { return nil }
        let meters = { (s: Stop) -> Double in
            guard let lat = s.lat, let lon = s.lon else { return .infinity }
            let x = (lon - vehicle.lon) * 111_320 * cos(vehicle.lat * .pi / 180), y = (lat - vehicle.lat) * 110_540
            return (x * x + y * y).squareRoot()
        }
        guard let nearest = route[...here].indices.min(by: { meters(route[$0]) < meters(route[$1]) }),
              meters(route[nearest]) < 400 else { return nil }
        return here - nearest
    }
}

/// A countdown to `date` ("4:12") that runs on its own, without updates; "now" once it's there.
struct Countdown: View {
    let date: Date
    let from: Date

    var body: some View {
        if date > .now {
            Text(timerInterval: min(from, date)...date, countsDown: true, showsHours: false)
                .monospacedDigit()
        } else {
            Text("now")
        }
    }
}

/// The whole minutes left until `date` ("12"), counting down on its own like `Countdown`, for where
/// "12:34" won't fit (the Dynamic Island's minimal circle, when another app's activity has the rest).
/// There's no minutes-only timer, so it's the countdown with its ":34" cut off; "now" once it's there.
struct MinutesLeft: View {
    let date: Date
    let from: Date
    var size: CGFloat = 15

    var body: some View {
        if date > .now {
            Text(timerInterval: min(from, date)...date, countsDown: true, showsHours: false)
                .font(.system(size: size, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                // As wide as "00:00", its digits against the right end (a timer left to size itself in a
                // widget takes all the room it's offered); then the seconds hang past the frame's end,
                // and get cut off with it.
                .frame(width: width(of: "00:00"), alignment: .trailing)
                .padding(.trailing, -width(of: ":00"))
                .clipped()
        } else {
            Text("now").font(.system(size: size * 0.8, weight: .heavy, design: .rounded))
        }
    }

    /// How wide `text` is set in the countdown's font.
    private func width(of text: String) -> CGFloat {
        var descriptor = UIFont.systemFont(ofSize: size, weight: .heavy).fontDescriptor
        descriptor = descriptor.withDesign(.rounded) ?? descriptor
        descriptor = descriptor.addingAttributes([.featureSettings: [[UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                                                                      UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector]]])
        return ceil((text as NSString).size(withAttributes: [.font: UIFont(descriptor: descriptor, size: size)]).width)
    }
}

/// The Lock Screen's view (and the Dynamic Island's, expanded): one line, as the widget next to it
/// already says which bus. Where it is and how fresh that is, and the countdown.
struct BusActivityView: View {
    let attributes: BusActivity
    let state: BusActivity.ContentState
    let isStale: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Two to a row: the card has height to spare, and the text and times need the width.
            LineBadges(parts: attributes.badgeParts, font: .system(.subheadline, design: .rounded).weight(.heavy),
                       round: attributes.round ?? false, columns: 2)
                .fixedSize()
            VStack(alignment: .leading, spacing: 1) {
                Text(isStale ? "Gone. Hope you made it." : whereItIs).font(.headline)
                    .lineLimit(1).minimumScaleFactor(0.8)
                if !isStale { freshness.font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8) }
            }
            Spacer(minLength: 4)
            if !isStale {
                VStack(alignment: .trailing, spacing: 1) {
                    Countdown(date: state.next, from: attributes.startedAt)
                        .font(.system(.title3, design: .rounded).weight(.heavy))
                        .foregroundStyle(state.nextIsLive ? .green : .secondary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 80, alignment: .trailing)
                    if let after = state.after {
                        // "then 1:56", without the AM or PM: it's minutes from now either way.
                        Text("then \(after.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var whereItIs: String {
        guard state.nextIsLive else { return "Schedule only" }
        switch state.stopsAway {
        case 0: return "At your stop"
        case 1: return "1 stop away"
        case let stops?: return "\(stops) stops away"
        // Live, but not on the map. Where vehicles never are (BART, PATH), it's just coming; elsewhere
        // the bus is keeping its whereabouts to itself.
        case nil: return attributes.showsVehicles == false ? "On its way" : "Live, but hiding"
        }
    }

    /// "Updated 20 sec ago", ticking on its own; for a schedule, that no bus has owned up to it yet.
    private var freshness: Text {
        guard state.nextIsLive else { return Text("No \(attributes.vehicle) owned up yet") }
        guard let updatedAt = state.updatedAt else { return Text("To \(attributes.destination)") }
        return Text("Updated ") + Text(updatedAt, style: .relative) + Text(" ago")
    }
}

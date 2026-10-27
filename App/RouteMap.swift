import MapKit
import SwiftUI

/// The selected line's route in the selected direction, the chosen stop, and the live buses
/// headed to it. Bus positions refresh as soon as the proxy can have newer data, which the bar
/// along the bottom counts down to.
struct RouteMap: View {
    let selection: Selection
    /// Shared with the departure list, so both always show the same buses and times.
    let feed: DepartureFeed
    var interactive = true
    /// Points at the top covered by something drawn over the map, kept clear of the route.
    var topInset: CGFloat = 0

    @State private var stops: [Stop] = []
    /// The real street route where the city provides one (Seattle); empty otherwise.
    @State private var shapes: [[CLLocationCoordinate2D]] = []
    /// The routes of the other lines a combined stop counts (the L and M besides the K).
    @State private var otherRoutes: [[CLLocationCoordinate2D]] = []
    @State private var position: MapCameraPosition = .automatic
    @State private var mapHeight: CGFloat = 0
    /// The selection whose route is drawn, to tell a move within a city from a fresh start.
    @State private var shownSelection: Selection?
    /// A live bus that was still on its way vanished from the latest data.
    @State private var busVanished = false

    /// The line to draw: the real route shape if there is one, else the stops joined in order.
    private var departures: [Departure] { feed.loaded?.id == selection.id ? feed.departures : [] }
    private var refresh: Refresh? { feed.loaded?.id == selection.id ? feed.refresh : nil }
    /// The current minute, ticking on the minute mark like the departure list's TimelineView,
    /// so the minutes on the map always match the list's.
    @State private var now = Date.currentMinute

    private var route: [[CLLocationCoordinate2D]] {
        (shapes.isEmpty ? [stops.compactMap(\.coordinate)] : shapes) + otherRoutes
    }
    private var selectedStop: Stop? { stops.first { $0.code == selection.stopCode } }
    /// Live buses on the route. 511 reports a trip's assigned bus wherever it is, so a bus still
    /// at the yard or finishing another trip would otherwise appear far off the line.
    private var buses: [(departure: Departure, vehicle: Vehicle)] {
        departures.compactMap { departure in
            guard let vehicle = departure.vehicle, isOnRoute(vehicle) else { return nil }
            return (departure, vehicle)
        }
    }

    /// Within 200 m of the drawn route.
    private func isOnRoute(_ vehicle: Vehicle) -> Bool {
        let segments = route.filter { $0.count > 1 }
        guard !segments.isEmpty else { return false }
        // Flat-earth meters around the bus; plenty accurate at city scale.
        let metersPerDegree = 111_320.0
        let lonScale = cos(vehicle.lat * .pi / 180)
        func local(_ c: CLLocationCoordinate2D) -> (x: Double, y: Double) {
            ((c.longitude - vehicle.lon) * metersPerDegree * lonScale, (c.latitude - vehicle.lat) * metersPerDegree)
        }
        for points in segments {
            for (a, b) in zip(points, points.dropFirst()) {
                let (p, q) = (local(a), local(b))
                let (dx, dy) = (q.x - p.x, q.y - p.y)
                let length = dx * dx + dy * dy
                let t = length > 0 ? max(0, min(1, -(p.x * dx + p.y * dy) / length)) : 0
                let (x, y) = (p.x + t * dx, p.y + t * dy)
                if x * x + y * y < 200 * 200 { return true }
            }
        }
        return false
    }

    var body: some View {
        Map(position: $position, interactionModes: interactive ? .all : []) {
            // Skip the line until the route has loaded.
            ForEach(Array(route.enumerated()), id: \.offset) { _, segment in
                if segment.count > 1 {
                    MapPolyline(coordinates: segment)
                        .stroke(LineBadge.red, style: StrokeStyle(lineWidth: interactive ? 5 : 4, lineCap: .round, lineJoin: .round))
                }
            }

            if interactive {
                ForEach(stops.filter { $0.code != selection.stopCode }) { stop in
                    if let coordinate = stop.coordinate {
                        Annotation(stop.name, coordinate: coordinate, anchor: .center) {
                            Circle()
                                .fill(.white)
                                .stroke(LineBadge.red, lineWidth: 2)
                                .frame(width: 9, height: 9)
                        }
                        .annotationTitles(.hidden)
                    }
                }
            }

            if let coordinate = selectedStop?.coordinate {
                Marker(selection.stopName, systemImage: "figure.wave", coordinate: coordinate)
                    .tint(.blue)
            }

            ForEach(buses, id: \.departure) { bus in
                // The minutes are part of the marker, not the annotation's title: MapKit hides titles
                // that collide with other labels (like the stop's name right next to it).
                Annotation("", coordinate: bus.vehicle.coordinate, anchor: .center) {
                    BusMarker(bearing: bus.vehicle.bearing, minutes: shortMinutes(bus.departure), isLive: bus.departure.isLive,
                              line: selection.isMultiLine ? bus.departure.line : nil, vehicle: selection.vehicle)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .safeAreaPadding(.top, topInset)
        // When the map changes size (pinned smaller over a scrolled list), frame the route again
        // instead of keeping the old zoom, which would show far too much around it.
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { height in
            defer { mapHeight = height }
            guard mapHeight > 0, abs(mapHeight - height) > 1, let rect = Self.boundingRect(of: route.joined()) else { return }
            withAnimation(.snappy(duration: 0.3)) { position = .rect(rect) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if interactive { statusCard }
                RefreshBar(refresh: refresh)
            }
        }
        .task {
            while !Task.isCancelled {
                now = .currentMinute
                try? await Task.sleep(until: .now + .seconds(now.addingTimeInterval(60).timeIntervalSinceNow), clock: .continuous)
            }
        }
        // The main screen stops updating the departures while this map is pushed over it, so the
        // full map keeps them coming itself.
        .task(id: selection) { if interactive { await feed.follow(selection) } }
        .task(id: selection) { [previous = shownSelection] in
            busVanished = false
            // Another stop in the same city: keep the old route up while the new one loads, then glide
            // the camera over to it. Anything else starts afresh.
            guard let previous, previous.city == selection.city, !stops.isEmpty else {
                stops = []
                shapes = []
                otherRoutes = []
                position = .automatic
                await loadRoute()
                shownSelection = selection
                return
            }
            await loadRoute(animated: true)
            shownSelection = selection
        }
        .onChange(of: feed.departures) { old, new in
            // Live buses that weren't due for another minute should still be in the new data;
            // fewer of them means one dropped off the map mid-route.
            let stillComing = old.filter { ($0.vehicle.map(isOnRoute) ?? false) && $0.time > .now + 60 }.count
            busVanished = new.filter { $0.vehicle.map(isOnRoute) ?? false }.count < stillComing
        }
        .onAppear { if interactive { feed.client = .map } }
        .onDisappear { if interactive { feed.client = .app } }
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            LineBadge(line: selection.lineLabel, font: .system(.title3, design: .rounded).weight(.heavy))
            VStack(alignment: .leading, spacing: 2) {
                if let next = buses.first {
                    Text("Next \(selection.vehicle) \(minutesLabel(next.departure) == "now" ? "arriving now" : "in \(minutesLabel(next.departure))")")
                        .font(.headline)
                } else {
                    Text("No \(selection.vehicles) on the way. Bold of you to look.").font(.headline)
                }
                Text("Live \(selection.vehicles) headed to \(selection.stopName), in theory")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if busVanished {
                    QuipText(Quip.vanished(line: selection.lineLabel))
                } else if let next = departures.first {
                    QuipText(Quip.forWait(until: next.time, from: now, line: next.line ?? selection.lineLabel))
                } else {
                    QuipText(Quip.noPrediction(line: selection.lineLabel))
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding()
    }

    /// "7" or "now", for the compact labels next to buses (no "min", to save space).
    private func shortMinutes(_ departure: Departure) -> String {
        let minutes = max(0, Int(departure.time.timeIntervalSince(now) / 60))
        return minutes == 0 ? "now" : "\(minutes)"
    }

    private func minutesLabel(_ departure: Departure) -> String {
        let minutes = max(0, Int(departure.time.timeIntervalSince(now) / 60))
        return minutes == 0 ? "now" : "\(minutes) min"
    }

    private func loadRoute(animated: Bool = false) async {
        let line = Line(id: selection.lineID, name: selection.lineName, mode: "bus")
        guard let directions = try? await TransitService.directions(for: line, in: selection.city, client: interactive ? .map : .app)
        else { return }
        let direction = directions.first { $0.id == selection.directionID } ?? directions.first
        let newStops = direction?.stops ?? []
        let newShapes = (direction?.shapes ?? []).map { segment in
            segment.compactMap { $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil }
        }
        // The other lines of a combined stop, drawn too so their buses show on the map.
        var others: [[CLLocationCoordinate2D]] = []
        for other in selection.also {
            let line = Line(id: other.lineID, name: "", mode: "bus")
            let stop = other.stopCode ?? selection.stopCode
            guard let directions = try? await TransitService.directions(for: line, in: selection.city, client: interactive ? .map : .app),
                  let direction = directions.first(where: { $0.id == other.directionID && $0.stops.contains { $0.code == stop } })
                      ?? directions.first(where: { $0.stops.contains { $0.code == stop } })
                      ?? directions.first(where: { $0.id == other.directionID }) ?? directions.first
            else { continue }
            let shape = (direction.shapes ?? []).map { segment in
                segment.compactMap { $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil }
            }
            others += shape.isEmpty ? [direction.stops.compactMap(\.coordinate)] : shape
        }
        let newRoute = (newShapes.isEmpty ? [newStops.compactMap(\.coordinate)] : newShapes) + others
        guard animated, let rect = Self.boundingRect(of: newRoute.joined()) else {
            stops = newStops
            shapes = newShapes
            otherRoutes = others
            return
        }
        withAnimation(.easeInOut(duration: 0.8)) {
            stops = newStops
            shapes = newShapes
            otherRoutes = others
            position = .rect(rect)
        }
    }

    /// The route's extent with a margin, about what `.automatic` frames.
    private static func boundingRect(of coordinates: some Sequence<CLLocationCoordinate2D>) -> MKMapRect? {
        let points = coordinates.map(MKMapPoint.init)
        guard let first = points.first else { return nil }
        let rect = points.dropFirst().reduce(MKMapRect(origin: first, size: MKMapSize())) {
            $0.union(MKMapRect(origin: $1, size: MKMapSize()))
        }
        return rect.insetBy(dx: -rect.width * 0.12, dy: -rect.height * 0.12)
    }

}

/// A few-points-tall bar that empties until the proxy's next 511 snapshot is ready.
private struct RefreshBar: View {
    let refresh: Refresh?

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25)) { context in
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.black.opacity(0.12))
                    Rectangle()
                        .fill(LineBadge.red)
                        .frame(width: geometry.size.width * (refresh?.remaining(at: context.date) ?? 0))
                }
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

private struct BusMarker: View {
    let bearing: Double?
    let minutes: String
    /// Green like every other live time in the app; grey for a scheduled-only estimate.
    let isLive: Bool
    /// On a combined stop, which line this bus is, shown instead of the bus icon.
    var line: String? = nil
    /// "bus", or "train" in the subway.
    var vehicle = "bus"

    var body: some View {
        ZStack {
            if let bearing {
                // Small arrow on the ring pointing the way the bus is heading.
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(LineBadge.red)
                    .offset(y: -22)
                    .rotationEffect(.degrees(bearing))
            }
            // A dark disc with the line-red ring, so the minutes can keep the app's green/grey.
            Circle()
                .fill(Color(white: 0.1))
                .overlay(Circle().strokeBorder(LineBadge.red, lineWidth: 3))
                .overlay(Circle().strokeBorder(.white, lineWidth: 1).padding(-1))
                .frame(width: 36, height: 36)
            VStack(spacing: 0) {
                if let line {
                    Text(line)
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: 26)
                } else {
                    Image(systemName: vehicle == "train" ? "tram.fill" : "bus.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text(minutes)
                    .font(.system(size: minutes.count > 2 ? 10 : 13, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isLive ? .green : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: 28)
            }
        }
        .shadow(radius: 2, y: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((line.map { "Line \($0), " } ?? "\(vehicle.capitalized), ") + (minutes == "now" ? "arriving now" : "\(minutes) minutes"))
    }
}

extension Stop {
    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

extension Vehicle {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

extension Date {
    /// The start of the current minute, the same moment `TimelineView(.everyMinute)` reports.
    static var currentMinute: Date {
        Calendar.current.dateInterval(of: .minute, for: .now)?.start ?? .now
    }
}

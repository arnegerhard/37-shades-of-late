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

    @State private var stops: [Stop] = []
    /// The real street route where the city provides one (Seattle); empty otherwise.
    @State private var shapes: [[CLLocationCoordinate2D]] = []
    @State private var position: MapCameraPosition = .automatic
    /// A live bus that was still on its way vanished from the latest data.
    @State private var busVanished = false

    /// The line to draw: the real route shape if there is one, else the stops joined in order.
    private var departures: [Departure] { feed.loaded?.id == selection.id ? feed.departures : [] }
    private var refresh: Refresh? { feed.loaded?.id == selection.id ? feed.refresh : nil }
    private var now: Date { feed.updatedAt }

    private var route: [[CLLocationCoordinate2D]] {
        shapes.isEmpty ? [stops.compactMap(\.coordinate)] : shapes
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
                Annotation(minutesLabel(bus.departure), coordinate: bus.vehicle.coordinate, anchor: .center) {
                    BusMarker(bearing: bus.vehicle.bearing)
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if interactive { statusCard }
                RefreshBar(refresh: refresh)
            }
        }
        .task(id: selection) {
            stops = []
            shapes = []
            busVanished = false
            position = .automatic
            await loadRoute()
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
            LineBadge(line: selection.lineID, font: .system(.title3, design: .rounded).weight(.heavy))
            VStack(alignment: .leading, spacing: 2) {
                if let next = buses.first {
                    Text("Next bus \(minutesLabel(next.departure) == "now" ? "arriving now" : "in \(minutesLabel(next.departure))")")
                        .font(.headline)
                } else {
                    Text("No buses on the way yet").font(.headline)
                }
                Text("Live buses headed to \(selection.stopName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if busVanished {
                    QuipText(Quip.vanished(line: selection.lineID))
                } else if let next = departures.first {
                    QuipText(Quip.forWait(until: next.time, from: now, line: selection.lineID))
                } else {
                    QuipText(Quip.noPrediction(line: selection.lineID))
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding()
    }

    private func minutesLabel(_ departure: Departure) -> String {
        let minutes = max(0, Int(departure.time.timeIntervalSince(now) / 60))
        return minutes == 0 ? "now" : "\(minutes) min"
    }

    private func loadRoute() async {
        let line = Line(id: selection.lineID, name: selection.lineName, mode: "bus")
        guard let directions = try? await TransitService.directions(for: line, in: selection.city, client: interactive ? .map : .app)
        else { return }
        let direction = directions.first { $0.id == selection.directionID } ?? directions.first
        stops = direction?.stops ?? []
        shapes = (direction?.shapes ?? []).map { segment in
            segment.compactMap { $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil }
        }
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

    var body: some View {
        ZStack {
            if let bearing {
                // Small arrow on the circle's edge pointing the way the bus is heading.
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(LineBadge.red)
                    .offset(y: -19)
                    .rotationEffect(.degrees(bearing))
            }
            Circle()
                .fill(LineBadge.red)
                .stroke(.white, lineWidth: 2)
                .frame(width: 30, height: 30)
            Image(systemName: "bus.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
        }
        .shadow(radius: 2, y: 1)
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

import MapKit
import SwiftUI

/// The selected line's route in the selected direction, the chosen stop, and the live buses
/// headed to it. Bus positions refresh as soon as the proxy can have newer 511 data,
/// which the bar along the bottom counts down to.
struct RouteMap: View {
    let selection: Selection
    var interactive = true

    @State private var stops: [Stop] = []
    @State private var departures: [Departure] = []
    @State private var position: MapCameraPosition = .automatic
    @State private var now = Date.now
    @State private var refresh: Refresh?
    /// A live bus that was still on its way vanished from the latest data.
    @State private var busVanished = false

    private var route: [CLLocationCoordinate2D] { stops.compactMap(\.coordinate) }
    private var selectedStop: Stop? { stops.first { $0.code == selection.stopCode } }
    /// Live buses on the route. 511 reports a trip's assigned bus wherever it is, so a bus still
    /// at the yard or finishing another trip would otherwise appear far off the line.
    private var buses: [(departure: Departure, vehicle: Vehicle)] {
        departures.compactMap { departure in
            guard let vehicle = departure.vehicle, isOnRoute(vehicle) else { return nil }
            return (departure, vehicle)
        }
    }

    /// Within 200 m of the line drawn between the route's stops.
    private func isOnRoute(_ vehicle: Vehicle) -> Bool {
        let points = route
        guard points.count > 1 else { return false }
        // Flat-earth meters around the bus; plenty accurate at city scale.
        let metersPerDegree = 111_320.0
        let lonScale = cos(vehicle.lat * .pi / 180)
        func local(_ c: CLLocationCoordinate2D) -> (x: Double, y: Double) {
            ((c.longitude - vehicle.lon) * metersPerDegree * lonScale, (c.latitude - vehicle.lat) * metersPerDegree)
        }
        for (a, b) in zip(points, points.dropFirst()) {
            let (p, q) = (local(a), local(b))
            let (dx, dy) = (q.x - p.x, q.y - p.y)
            let length = dx * dx + dy * dy
            let t = length > 0 ? max(0, min(1, -(p.x * dx + p.y * dy) / length)) : 0
            let (x, y) = (p.x + t * dx, p.y + t * dy)
            if x * x + y * y < 200 * 200 { return true }
        }
        return false
    }

    var body: some View {
        Map(position: $position, interactionModes: interactive ? .all : []) {
            // Skip the line until the route has loaded.
            if route.count > 1 {
                MapPolyline(coordinates: route)
                    .stroke(LineBadge.red, style: StrokeStyle(lineWidth: interactive ? 5 : 4, lineCap: .round, lineJoin: .round))
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
            departures = []
            refresh = nil
            busVanished = false
            position = .automatic
            await loadRoute()
            while !Task.isCancelled {
                await loadDepartures()
                // Ask again as soon as the proxy's next snapshot is ready; if that time has
                // passed (511 budget spent), retry every few seconds instead of hammering it.
                let next = refresh?.nextRefreshAt ?? .now
                try? await Task.sleep(for: .seconds(max(5, next.timeIntervalSinceNow + 0.5)))
            }
        }
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
        guard let directions = try? await TransitService.directions(for: line, client: interactive ? .map : .app) else { return }
        stops = (directions.first { $0.id == selection.directionID } ?? directions.first)?.stops ?? []
    }

    private func loadDepartures() async {
        if let latest = try? await TransitService.snapshot(for: selection, client: interactive ? .map : .app) {
            // Live buses that weren't due for another minute should still be in the new data;
            // fewer of them means one dropped off the map mid-route.
            let stillComing = buses.filter { $0.departure.time > .now + 60 }.count
            let onRoute = latest.departures.filter { $0.vehicle.map(isOnRoute) ?? false }.count
            busVanished = onRoute < stillComing
            departures = latest.departures
            refresh = latest.refresh
        }
        now = .now
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

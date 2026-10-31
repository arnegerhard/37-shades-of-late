import MapKit
import SwiftUI
import simd

/// The selected line's route in the selected direction, the chosen stop, and the live buses
/// headed to it, on the home screen. Bus positions refresh as soon as the proxy can have newer data,
/// which the bar along the bottom counts down to. Two fingers move it (see `MapGesture`).
struct RouteMap: View {
    let selection: Selection
    /// Shared with the departure list, so both always show the same buses and times.
    let feed: DepartureFeed
    /// Points at the top covered by something drawn over the map, kept clear of the route.
    var topInset: CGFloat = 0
    /// Points at the top cut off by whatever holds the map (the home screen's, shrunk over a scrolled
    /// list), also kept clear of the route. Only changed once the list is at rest.
    var cropped: CGFloat = 0
    /// Two fingers moving the map, as they go.
    var gesture: MapGesture? = nil

    @State private var stops: [Stop] = []
    /// Each line's route, the selected line's first, then the others a combined stop counts (the L and
    /// M besides the K), with where they share a track.
    @State private var tracks: [Track] = []
    /// Meters per point at the map's zoom, for setting lines on a shared track side by side.
    @State private var metersPerPoint: Double = 0
    /// Each bus on its way, gliding along its route between the feed's updates (see `Glide`).
    @State private var glides: [Departure: Glide] = [:]
    /// Moves the gliding buses along, once a second.
    @State private var tick = Date.now
    /// What the map shows as it moves, for keeping the buses over it in place.
    @State private var shown: MKMapRect?
    @Environment(\.colorScheme) private var colorScheme
    @State private var position: MapCameraPosition = .automatic
    @State private var mapSize: CGSize = .zero
    /// The height of map showing that the route was last framed for.
    @State private var fittedRoom: CGFloat = 0
    /// The selection whose route is drawn, to tell a move within a city from a fresh start.
    @State private var shownSelection: Selection?

    private var departures: [Departure] { feed.loaded?.id == selection.id ? feed.departures : [] }
    private var refresh: Refresh? { feed.loaded?.id == selection.id ? feed.refresh : nil }
    /// The current minute, ticking on the minute mark like the departure list's TimelineView,
    /// so the minutes on the map always match the list's.
    @State private var now = Date.currentMinute

    /// Every line's route, as it runs.
    private var route: [[CLLocationCoordinate2D]] {
        tracks.flatMap { $0.segments.map { $0.map(\.coordinate) } }
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
        MapReader { proxy in
            Map(position: $position, bounds: selection.city.cameraBounds, interactionModes: []) {
                // Each line in its color, the selected one on top; where they share a track, side by side.
                ForEach(Array(tracks.enumerated().reversed()), id: \.offset) { _, track in
                    let color = Self.color(of: track.lineID, in: selection.city).legible(on: colorScheme)
                    ForEach(Array(track.segments.enumerated()), id: \.offset) { _, segment in
                        if segment.count > 1 {
                            MapPolyline(coordinates: segment.map { $0.shifted(by: (Self.lineWidth + Self.lineGap) * metersPerPoint) })
                                .stroke(color, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round))
                        }
                    }
                }

                if let coordinate = selectedStop?.coordinate {
                    // No title: the pill over the map names the stop, and buses arriving sit on the title,
                    // which MapKit then keeps hiding and showing again as they move.
                    Marker(selection.stopName, systemImage: "figure.wave", coordinate: coordinate)
                        .tint(.blue)
                        .annotationTitles(.hidden)
                }
            }
            // The buses over the map rather than in it: MapKit hides its labels under annotations, and
            // with buses moving that had street names flickering in and out wherever they passed.
            .overlay { busLayer(proxy) }
            .modifier(FollowsGesture(gesture: gesture, city: selection.city, proxy: proxy, position: $position))
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .safeAreaPadding(.top, topInset)
        // When the map's room changes (its size, or how much of it is cut off), frame the route again
        // instead of keeping the old zoom, which would show far too much around it, or cut it off.
        .onGeometryChange(for: CGSize.self, of: \.size) { mapSize = $0 }
        .onMapCameraChange(frequency: .continuous) { context in
            shown = context.rect
            guard mapSize.height > 0 else { return }
            let meters = context.region.span.latitudeDelta * 110_540 / mapSize.height
            if abs(meters - metersPerPoint) > metersPerPoint * 0.02 { metersPerPoint = meters }
        }
        .task(id: mapSize.height - cropped) {
            let room = mapSize.height - cropped
            // Without a route yet, it'll be framed for this room once it loads.
            guard fittedRoom > 0, abs(fittedRoom - room) > 1, let route = Self.boundingRect(of: route.joined()) else {
                fittedRoom = room
                return
            }
            fittedRoom = room
            // Cut off at the top, the route goes in what's left: a frame for the whole map with the
            // route in its lower part. (Changing the map's safe area instead would jump the camera.)
            let rect = Self.frame(route, in: CGSize(width: mapSize.width, height: mapSize.height - topInset), showing: room - topInset)
            // The same frame as a region when it's already this rect: setting an equal position again
            // wouldn't move the camera.
            withAnimation(.smooth(duration: 0.6)) { position = position == .rect(rect) ? .region(MKCoordinateRegion(rect)) : .rect(rect) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { RefreshBar(refresh: refresh) }
        .task {
            while !Task.isCancelled {
                now = .currentMinute
                try? await Task.sleep(until: .now + .seconds(now.addingTimeInterval(60).timeIntervalSinceNow), clock: .continuous)
            }
        }
        // New positions: each bus snaps to where it was reported, and glides on from there.
        .task(id: Pair(departures, tracks.count)) { glides = Glide.update(glides, buses: buses, tracks: tracks, stop: selectedStop?.coordinate) }
        // Only while one is still on the move: redrawing the map for buses that wait makes its labels flicker.
        .task(id: glides) {
            while !Task.isCancelled, glides.values.contains(where: { $0.isMoving(at: .now) }) {
                try? await Task.sleep(for: .seconds(1))
                withAnimation(.linear(duration: 1)) { tick = .now }
            }
        }
        .task(id: selection) { [previous = shownSelection] in
            // Another stop in the same city: keep the old route up while the new one loads, then glide
            // the camera over to it. Anything else starts afresh.
            guard let previous, previous.city == selection.city, !stops.isEmpty else {
                stops = []
                tracks = []
                position = .automatic
                await loadRoute()
                shownSelection = selection
                return
            }
            await loadRoute(animated: true)
            shownSelection = selection
        }
    }

    /// Each bus where it's got to since it was last reported, at its pace along the route, placed
    /// over the map where it shows that spot: as MapKit says, or while it can't (in the middle of a
    /// pinch), worked out from the area it shows, so the buses don't go missing until it stops.
    private func busLayer(_ proxy: MapProxy) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(buses, id: \.departure) { bus in
                let place = glides[bus.departure]?.place(at: tick)
                let coordinate = place?.coordinate ?? bus.vehicle.coordinate
                if let point = proxy.convert(coordinate, to: .local) ?? estimatedPoint(of: coordinate) {
                    BusMarker(bearing: place?.bearing ?? bus.vehicle.bearing, minutes: shortMinutes(bus.departure), isLive: bus.departure.isLive,
                              line: selection.isMultiLine ? bus.departure.line : nil, vehicle: selection.vehicle,
                              color: Self.color(of: bus.departure.line ?? selection.lineID, in: selection.city))
                        .position(point)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// Where the map shows `coordinate`, from the area it shows: the area below the room kept clear at
    /// the top (`topInset`), which is also where the buses' layer starts.
    private func estimatedPoint(of coordinate: CLLocationCoordinate2D) -> CGPoint? {
        guard let shown, shown.width > 0, shown.height > 0 else { return nil }
        let spot = MKMapPoint(coordinate)
        return CGPoint(x: (spot.x - shown.minX) / shown.width * mapSize.width,
                       y: (spot.y - shown.minY) / shown.height * (mapSize.height - topInset))
    }

    private static let lineWidth: CGFloat = 4
    /// The room between lines side by side on a track, so their colors don't run together.
    private static let lineGap: CGFloat = 2.5

    /// A line's own color, as its badge has it, or the app's red.
    static func color(of line: String, in city: City) -> Color {
        Color(hex: LineBadge.color(of: line, in: city)?.hex) ?? LineBadge.red
    }

    /// "7" or "now", for the compact labels next to buses (no "min", to save space).
    private func shortMinutes(_ departure: Departure) -> String {
        let minutes = max(0, Int(departure.time.timeIntervalSince(now) / 60))
        return minutes == 0 ? "now" : "\(minutes)"
    }

    private func loadRoute(animated: Bool = false) async {
        let line = Line(id: selection.lineID, name: selection.lineName, mode: "bus")
        guard let directions = try? await TransitService.directions(for: line, in: selection.city) else { return }
        let direction = directions.first { $0.id == selection.directionID } ?? directions.first
        let newStops = direction?.stops ?? []
        // Each line's route: the real street shape where there is one, else its stops joined in order.
        func route(of direction: Direction?) -> [[CLLocationCoordinate2D]] {
            let shape = (direction?.shapes ?? []).map { segment in
                segment.compactMap { $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil }
            }
            return shape.isEmpty ? [(direction?.stops ?? []).compactMap(\.coordinate)] : shape
        }
        var lines = [(id: selection.lineID, segments: route(of: direction))]
        // The other lines of a combined stop, drawn too so their buses show on the map.
        for other in selection.also {
            let line = Line(id: other.lineID, name: "", mode: "bus")
            let stop = other.stopCode ?? selection.stopCode
            guard let directions = try? await TransitService.directions(for: line, in: selection.city),
                  let direction = directions.first(where: { $0.id == other.directionID && $0.stops.contains { $0.code == stop } })
                      ?? directions.first(where: { $0.stops.contains { $0.code == stop } })
                      ?? directions.first(where: { $0.id == other.directionID }) ?? directions.first
            else { continue }
            lines.append((other.lineID, route(of: direction)))
        }
        // Lines drawn in the same color share a slot: side by side they'd only show it twice.
        let city = selection.city
        let colored = lines.map { (id: $0.id, color: LineBadge.color(of: $0.id, in: city)?.hex ?? "", segments: $0.segments) }
        let newTracks = await Task.detached(priority: .userInitiated) { Track.build(colored) }.value
        guard animated, let rect = Self.boundingRect(of: lines.flatMap(\.segments).joined()) else {
            stops = newStops
            tracks = newTracks
            return
        }
        withAnimation(.easeInOut(duration: 0.8)) {
            stops = newStops
            tracks = newTracks
            position = .rect(cropped > 0 ? Self.frame(rect, in: CGSize(width: mapSize.width, height: mapSize.height - topInset),
                                                      showing: mapSize.height - cropped - topInset) : rect)
        }
    }

    /// A frame for a map of `size` (points) that fits `route` into its bottom `height` points.
    private static func frame(_ route: MKMapRect, in size: CGSize, showing height: CGFloat) -> MKMapRect {
        guard size.width > 0, height > 0 else { return route }
        let scale = max(route.width / size.width, route.height / height)
        let width = size.width * scale, fullHeight = size.height * scale
        let bottom = route.midY + height / 2 * scale
        return MKMapRect(x: route.midX - width / 2, y: bottom - fullHeight, width: width, height: fullHeight)
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

/// A line's route on the home map, and where it shares a track with the others drawn: there they
/// sit side by side, as on Google's maps, each in its own slot across the bundle, in the same order
/// all along it.
struct Track: @unchecked Sendable {
    let lineID: String
    let segments: [[Point]]

    struct Point {
        let coordinate: CLLocationCoordinate2D
        /// Across the track, as meters east and north (a unit vector), the same way for every line on it.
        let across: SIMD2<Double>
        /// Its slot, in line widths from the middle of the bundle: 0 alone, -0.5 and 0.5 for two.
        let slot: Double

        /// Where it's drawn when lines side by side are `width` meters apart, middle to middle.
        func shifted(by width: Double) -> CLLocationCoordinate2D {
            guard slot != 0, width > 0 else { return coordinate }
            let meters = across * slot * width
            return CLLocationCoordinate2D(latitude: coordinate.latitude + meters.y / 110_540,
                                          longitude: coordinate.longitude + meters.x / (111_320 * cos(coordinate.latitude * .pi / 180)))
        }
    }

    /// Lines on one track: within this many meters of each other, running nearly parallel (either way).
    private static let sameTrack = 25.0

    /// `color`: lines of the same color (the same line twice, or lines with no color of their own) take one slot.
    static func build(_ lines: [(id: String, color: String, segments: [[CLLocationCoordinate2D]])]) -> [Track] {
        guard let origin = lines.lazy.flatMap({ $0.segments.joined() }).first else {
            return lines.map { Track(lineID: $0.id, segments: []) }
        }
        // Flat-earth meters around the first point; plenty accurate at city scale.
        let lonScale = 111_320 * cos(origin.latitude * .pi / 180)
        func local(_ c: CLLocationCoordinate2D) -> SIMD2<Double> {
            SIMD2((c.longitude - origin.longitude) * lonScale, (c.latitude - origin.latitude) * 110_540)
        }
        let flat = lines.map { $0.segments.map { $0.map(local) } }
        // Each line's pieces of route by 50 m square, to find the ones near a point quickly.
        let cell = 50.0
        func key(_ p: SIMD2<Double>) -> SIMD2<Int> { SIMD2(Int((p.x / cell).rounded(.down)), Int((p.y / cell).rounded(.down))) }
        let grids = flat.map { segments in
            var grid: [SIMD2<Int>: [(a: SIMD2<Double>, b: SIMD2<Double>)]] = [:]
            for points in segments {
                for (a, b) in zip(points, points.dropFirst()) {
                    let steps = max(1, Int((simd_distance(a, b) / (cell / 2)).rounded(.up)))
                    var seen = Set<SIMD2<Int>>()
                    for step in 0...steps {
                        let k = key(a + (b - a) * (Double(step) / Double(steps)))
                        if seen.insert(k).inserted { grid[k, default: []].append((a, b)) }
                    }
                }
            }
            return grid
        }
        /// Which way line `j` runs (as drawn) where it shares the track at `p` heading along `way`.
        func along(_ j: Int, at p: SIMD2<Double>, way: SIMD2<Double>) -> SIMD2<Double>? {
            let k = key(p)
            for dx in -1...1 {
                for dy in -1...1 {
                    for (a, b) in grids[j][SIMD2(k.x + dx, k.y + dy)] ?? [] {
                        let ab = b - a, length = simd_length(ab)
                        guard length > 0 else { continue }
                        let t = max(0, min(1, simd_dot(p - a, ab) / (length * length)))
                        if simd_distance(p, a + ab * t) < sameTrack, abs(simd_dot(ab / length, way)) > 0.85 { return ab / length }
                    }
                }
            }
            return nil
        }
        return lines.indices.map { i in
            Track(lineID: lines[i].id, segments: zip(lines[i].segments, flat[i]).map { coordinates, points in
                points.indices.map { v in
                    let way = points[min(v + 1, points.count - 1)] - points[max(v - 1, 0)]
                    guard simd_length(way) > 0 else { return Point(coordinate: coordinates[v], across: .zero, slot: 0) }
                    let ways = lines.indices.map { $0 == i ? simd_normalize(way) : along($0, at: points[v], way: simd_normalize(way)) }
                    let sharing = lines.indices.filter { ways[$0] != nil }
                    // A slot per color on the track, in the order the lines come.
                    var colors: [String] = []
                    for j in sharing where !colors.contains(lines[j].color) { colors.append(lines[j].color) }
                    guard colors.count > 1, let first = sharing.first, let reference = ways[first] else {
                        return Point(coordinate: coordinates[v], across: .zero, slot: 0)
                    }
                    // Across the way the bundle's first line runs, so every line on it agrees on the side.
                    return Point(coordinate: coordinates[v], across: SIMD2(reference.y, -reference.x),
                                 slot: Double(colors.firstIndex(of: lines[i].color)!) - Double(colors.count - 1) / 2)
                }
            })
        }
    }
}

/// Two values as one task id.
private struct Pair<A: Equatable, B: Equatable>: Equatable {
    let a: A, b: B
    init(_ a: A, _ b: B) { self.a = a; self.b = b }
}

/// One stretch of a line's route, flat in meters, for how far along it a bus is and where that is.
struct RoutePath {
    let coordinates: [CLLocationCoordinate2D]
    private let points: [SIMD2<Double>]
    /// Meters from the start to each point.
    private let along: [Double]
    private let origin: CLLocationCoordinate2D
    private let lonScale: Double

    init?(_ coordinates: [CLLocationCoordinate2D]) {
        guard coordinates.count > 1, let origin = coordinates.first else { return nil }
        self.coordinates = coordinates
        self.origin = origin
        lonScale = 111_320 * cos(origin.latitude * .pi / 180)
        let points = coordinates.map { SIMD2(($0.longitude - origin.longitude) * 111_320 * cos(origin.latitude * .pi / 180),
                                             ($0.latitude - origin.latitude) * 110_540) }
        self.points = points
        var along = [0.0]
        for (a, b) in zip(points, points.dropFirst()) { along.append(along.last! + simd_distance(a, b)) }
        self.along = along
    }

    var length: Double { along.last ?? 0 }

    private func local(_ c: CLLocationCoordinate2D) -> SIMD2<Double> {
        SIMD2((c.longitude - origin.longitude) * lonScale, (c.latitude - origin.latitude) * 110_540)
    }

    /// How far along it the point nearest `coordinate` is, and how far off it `coordinate` is.
    func locate(_ coordinate: CLLocationCoordinate2D) -> (meters: Double, off: Double) {
        let p = local(coordinate)
        var best = (meters: 0.0, off: Double.infinity)
        for i in points.indices.dropLast() {
            let a = points[i], ab = points[i + 1] - a, length = simd_length_squared(ab)
            let t = length > 0 ? max(0, min(1, simd_dot(p - a, ab) / length)) : 0
            let off = simd_distance(p, a + ab * t)
            if off < best.off { best = (along[i] + t * (along[i + 1] - along[i]), off) }
        }
        return best
    }

    /// Where it is `meters` along, and which way it heads there (degrees from north).
    func place(at meters: Double) -> (coordinate: CLLocationCoordinate2D, bearing: Double) {
        let meters = max(0, min(meters, length))
        let i = max(0, min((along.lastIndex { $0 <= meters } ?? 0), points.count - 2))
        let span = along[i + 1] - along[i]
        let t = span > 0 ? (meters - along[i]) / span : 0
        let p = points[i] + (points[i + 1] - points[i]) * t
        let way = points[i + 1] - points[i]
        let bearing = (atan2(way.x, way.y) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        return (CLLocationCoordinate2D(latitude: origin.latitude + p.y / 110_540, longitude: origin.longitude + p.x / lonScale), bearing)
    }
}

/// A bus between the feed's updates: where along its route it was last reported, and how fast it's
/// been going, to move it on at that pace until the next report snaps it to where it really is.
/// The feed doesn't say which bus is which, so the same bus is the one that was a little behind on
/// the same stretch of the same line last time. One seen for the first time goes at the pace that
/// gets it to the stop when it's predicted to; none goes past the stop.
struct Glide: Equatable {
    static func == (a: Glide, b: Glide) -> Bool {
        a.line == b.line && a.stretch == b.stretch && a.meters == b.meters && a.at == b.at && a.speed == b.speed && a.end == b.end
    }

    let line: String
    let path: RoutePath
    let stretch: Int
    /// Meters along `path` when reported, and when that was.
    let meters: Double
    let at: Date
    /// Meters per second.
    let speed: Double
    /// As far as it goes: the stop, or the end of the stretch.
    let end: Double

    /// The longest a bus glides on without news: after that it waits where it's got to.
    private static let longest: TimeInterval = 120
    /// Faster than any city vehicle gets between stops (about 90 km/h).
    private static let fastest = 25.0

    /// Whether it's still going somewhere at `date`: not yet at the stop, and not out of news too long.
    func isMoving(at date: Date) -> Bool {
        let seconds = date.timeIntervalSince(at)
        return speed > 0 && seconds < Self.longest && meters + speed * seconds < end
    }

    func place(at date: Date) -> (coordinate: CLLocationCoordinate2D, bearing: Double) {
        let gone = speed * min(max(0, date.timeIntervalSince(at)), Self.longest)
        return path.place(at: min(meters + gone, max(end, meters)))
    }

    static func update(_ previous: [Departure: Glide], buses: [(departure: Departure, vehicle: Vehicle)], tracks: [Track],
                       stop: CLLocationCoordinate2D?) -> [Departure: Glide] {
        let now = Date.now
        var unclaimed = Array(previous.values)
        var glides: [Departure: Glide] = [:]
        for (departure, vehicle) in buses {
            let line = departure.line ?? tracks.first?.lineID ?? ""
            guard let track = tracks.first(where: { $0.lineID == line }) ?? tracks.first else { continue }
            // The stretch of its route it's on.
            let found = track.segments.enumerated().compactMap { index, points -> (Int, RoutePath, Double, Double)? in
                guard let path = RoutePath(points.map(\.coordinate)) else { return nil }
                let spot = path.locate(vehicle.coordinate)
                return (index, path, spot.meters, spot.off)
            }.min { $0.3 < $1.3 }
            guard let (stretch, path, meters, off) = found, off < 200 else { continue }
            let stopMeters = stop.map { path.locate($0) }
            let end = stopMeters.map { $0.off < 200 && $0.meters >= meters ? $0.meters : path.length } ?? path.length
            // The same bus last time: same line and stretch, a little behind (or just where it was).
            let match = unclaimed.enumerated().filter { _, glide in
                let seconds = now.timeIntervalSince(glide.at)
                return glide.line == line && glide.stretch == stretch && glide.meters <= meters + 30
                    && meters - glide.meters <= fastest * seconds + 200
            }.min { abs($0.1.meters - meters) < abs($1.1.meters - meters) }
            let speed: Double
            if let (index, before) = match {
                unclaimed.remove(at: index)
                let seconds = now.timeIntervalSince(before.at)
                // Asked again before anything moved: keep its pace.
                speed = seconds < 15 ? before.speed : max(0, meters - before.meters) / seconds
            } else {
                // Its pace to make the predicted time at the stop.
                let seconds = departure.time.timeIntervalSince(now)
                speed = seconds > 30 ? max(0, end - meters) / seconds : 0
            }
            glides[departure] = Glide(line: line, path: path, stretch: stretch, meters: meters,
                                      at: now, speed: min(speed, fastest), end: end)
        }
        return glides
    }
}

/// Two fingers on a home map: how far they've pinched (2 is twice as close), how far they've moved
/// together, and where they started, in the map's own points.
struct MapGesture: Equatable {
    var scale: CGFloat
    var translation: CGPoint
    var start: CGPoint

    /// The same, for a map whose top `points` are cut off above where it was measured.
    func moved(down points: CGFloat) -> MapGesture {
        MapGesture(scale: scale, translation: translation, start: CGPoint(x: start.x, y: start.y + points))
    }
}

/// Moves a map that takes no touches itself as two fingers do: from the camera it had as they came
/// down, the point they started on stays under them, closer or further as they pinch. No further
/// out than the city allows (`City.farthest`), nor closer than a few blocks, nor off the city.
private struct FollowsGesture: ViewModifier {
    let gesture: MapGesture?
    let city: City
    let proxy: MapProxy
    @Binding var position: MapCameraPosition
    @State private var camera: MapCamera?
    /// The camera as the fingers came down, the map point under them, and map points per point.
    @State private var start: (camera: MapCamera, focus: MKMapPoint, perPoint: Double)?

    func body(content: Content) -> some View {
        content
            .onMapCameraChange(frequency: .continuous) { camera = $0.camera }
            .onChange(of: gesture) {
                guard let gesture else { start = nil; return }
                if start == nil, let camera, let here = proxy.convert(gesture.start, from: .local),
                   let across = proxy.convert(CGPoint(x: gesture.start.x + 100, y: gesture.start.y), from: .local) {
                    start = (camera, MKMapPoint(here), (MKMapPoint(across).x - MKMapPoint(here).x) / 100)
                }
                guard let start, gesture.scale > 0 else { return }
                let distance = min(max(start.camera.distance / gesture.scale, 400), city.farthest)
                let grown = start.camera.distance / distance
                // The middle moves toward the focus as much as the map grows, then along with the fingers.
                let middle = MKMapPoint(start.camera.centerCoordinate)
                let perPoint = start.perPoint / grown
                let center = MKMapPoint(x: start.focus.x + (middle.x - start.focus.x) / grown - gesture.translation.x * perPoint,
                                        y: start.focus.y + (middle.y - start.focus.y) / grown - gesture.translation.y * perPoint)
                var moved = start.camera
                moved.centerCoordinate = city.keepingInside(center.coordinate)
                moved.distance = distance
                position = .camera(moved)
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
    let minutes: String
    /// Green like every other live time in the app; grey for a scheduled-only estimate.
    let isLive: Bool
    /// On a combined stop, which line this bus is, shown instead of the bus icon.
    var line: String? = nil
    /// As `Selection.vehicle`: "bus", "train", "streetcar", "cable car" or "ferry".
    var vehicle = "bus"
    /// Its line's color, for the ring and the arrow.
    var color = LineBadge.red

    var body: some View {
        ZStack {
            if let bearing {
                // Small arrow on the ring pointing the way the bus is heading.
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(color)
                    .offset(y: -22)
                    .rotationEffect(.degrees(bearing))
            }
            // A dark disc with a ring in the line's color, so the minutes can keep the app's green/grey.
            Circle()
                .fill(Color(white: 0.1))
                .overlay(Circle().strokeBorder(color, lineWidth: 3))
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
                    Image(systemName: vehicle == "bus" ? "bus.fill" : vehicle == "ferry" ? "ferry.fill" : vehicle == "cable car" ? "cablecar.fill" : "tram.fill")
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

/// A city's main lines (trains, rapid and select buses) on one quiet map, for the home screen
/// before any stop there is a favorite: what there is to pick from, in its own colors.
struct CityLinesMap: View {
    let city: City
    /// Two fingers moving the map, as they go.
    var gesture: MapGesture? = nil
    @State private var lines: [MapLine] = []
    @State private var position: MapCameraPosition
    @Environment(\.colorScheme) private var colorScheme

    init(city: City, gesture: MapGesture? = nil) {
        self.city = city
        self.gesture = gesture
        _position = State(initialValue: .region(city.region))
    }

    var body: some View {
        MapReader { proxy in
            Map(position: $position, bounds: city.cameraBounds, interactionModes: []) {
                ForEach(lines) { line in
                    let color = line.mapColor.legible(on: colorScheme)
                    let shapes = line.shapes.map { $0.compactMap { $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil } }
                    // Ferries dashed across the water, in pieces (see LineLayer.dashed).
                    ForEach(Array((line.mode == "ferry" ? shapes.flatMap { LineLayer.dashed($0) } : shapes).enumerated()), id: \.offset) { _, shape in
                        MapPolyline(coordinates: shape)
                            .stroke(color, style: StrokeStyle(lineWidth: line.mode == "bus" ? 2 : 3, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            .modifier(FollowsGesture(gesture: gesture, city: city, proxy: proxy, position: $position))
        }
        .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
        .task(id: city) {
            // Buses underneath, so the trains read on top of them.
            // Off the main thread: New York's map is big.
            let main = await Task.detached(priority: .userInitiated) {
                TransitService.cachedLineMap(in: city).filter { LineLabels.tier(of: $0) == 0 }
            }.value
            lines = main.filter { $0.mode == "bus" } + main.filter { $0.mode != "bus" }
        }
    }
}

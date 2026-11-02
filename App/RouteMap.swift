import MapKit
import SwiftUI
import simd

/// The open stop's route in its direction, the stop, and the live buses headed to it: what the home
/// map (`HomeMap`) shows of a stop, with every other line taken off. Bus positions refresh as soon as
/// the proxy can have newer data, which the bar along the bottom counts down to.
@Observable @MainActor
final class LiveRoute {
    /// The stop whose route is drawn.
    private(set) var selection: Selection?
    private(set) var stops: [Stop] = []
    /// Each line's route, the selected line's first, then the others a combined stop counts (the L and
    /// M besides the K), with where they share a track.
    private(set) var tracks: [Track] = []
    /// Each bus on its way, gliding along its route between the feed's updates (see `Glide`).
    var glides: [Departure: Glide] = [:]
    /// Moves the gliding buses along, once a second.
    var tick = Date.now
    /// The current minute, ticking on the minute mark like the departure list's TimelineView,
    /// so the minutes on the map always match the list's.
    var now = Date.currentMinute

    /// Every line's route, as it runs.
    var route: [[CLLocationCoordinate2D]] {
        tracks.flatMap { $0.segments.map { $0.map(\.coordinate) } }
    }
    var selectedStop: Stop? { stops.first { $0.code == selection?.stopCode } }

    /// The route's extent with a margin, about what `.automatic` frames.
    var bounds: MKMapRect? {
        let points = route.joined().map(MKMapPoint.init)
        guard let first = points.first else { return nil }
        let rect = points.dropFirst().reduce(MKMapRect(origin: first, size: MKMapSize())) {
            $0.union(MKMapRect(origin: $1, size: MKMapSize()))
        }
        return rect.insetBy(dx: -rect.width * 0.12, dy: -rect.height * 0.12)
    }

    /// Live buses on the route, on their way to the stop. 511 reports a trip's assigned bus wherever
    /// it is, so a bus still at the yard or finishing another trip would otherwise appear far off the
    /// line, or on it past the stop, where it went by on its last trip.
    func buses(in departures: [Departure]) -> [(departure: Departure, vehicle: Vehicle)] {
        departures.compactMap { departure in
            guard let vehicle = departure.vehicle, isOnRoute(vehicle),
                  !isPastStop(vehicle, line: departure.line ?? selection?.lineID) else { return nil }
            return (departure, vehicle)
        }
    }

    /// Further along its line's route than the stop, by more than a bus's length or two. Only where
    /// the route passes the stop (another line of a combined stop may be caught a walk away).
    private func isPastStop(_ vehicle: Vehicle, line: String?) -> Bool {
        guard let stop = selectedStop?.coordinate,
              let track = tracks.first(where: { $0.lineID == line }) ?? tracks.first else { return false }
        let found = track.segments.compactMap { RoutePath($0.map(\.coordinate)) }
            .map { (path: $0, bus: $0.locate(vehicle.coordinate)) }
            .min { $0.bus.off < $1.bus.off }
        guard let found, found.bus.off < 200 else { return false }
        let spot = found.path.locate(stop)
        return spot.off < 60 && found.bus.meters > spot.meters + 40
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

    /// Nothing drawn.
    func clear() {
        selection = nil
        stops = []
        tracks = []
        glides = [:]
    }

    /// `selection`'s stops and routes, to `show`.
    static func load(_ selection: Selection) async -> (selection: Selection, stops: [Stop], tracks: [Track])? {
        let line = Line(id: selection.lineID, name: selection.lineName, mode: "bus")
        guard let directions = try? await TransitService.directions(for: line, in: selection.city) else { return nil }
        let direction = directions.first { $0.id == selection.directionID } ?? directions.first
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
        let tracks = await Task.detached(priority: .userInitiated) { Track.build(colored) }.value
        return (selection, direction?.stops ?? [], tracks)
    }

    func show(_ loaded: (selection: Selection, stops: [Stop], tracks: [Track])) {
        selection = loaded.selection
        stops = loaded.stops
        tracks = loaded.tracks
    }

    /// "7" or "now", for the compact labels next to buses (no "min", to save space).
    func shortMinutes(_ departure: Departure) -> String {
        let minutes = max(0, Int(departure.time.timeIntervalSince(now) / 60))
        return minutes == 0 ? "now" : "\(minutes)"
    }

    /// A line's own color, as its badge has it, or the app's red.
    static func color(of line: String, in city: City) -> Color {
        Color(hex: LineBadge.color(of: line, in: city)?.hex) ?? LineBadge.red
    }

    /// A frame for a map of `size` (points) that fits `route` into the points from `band`'s top to its bottom.
    static func frame(_ route: MKMapRect, in size: CGSize, band: ClosedRange<CGFloat>) -> MKMapRect {
        let height = band.upperBound - band.lowerBound
        guard size.width > 0, height > 0 else { return route }
        let scale = max(route.width / size.width, route.height / height)
        let top = route.midY - (band.lowerBound + band.upperBound) / 2 * scale
        return MKMapRect(x: route.midX - size.width * scale / 2, y: top, width: size.width * scale, height: size.height * scale)
    }
}

/// What changes on the home map as it moves, frame by frame, read only where it's needed: changed in
/// the map's own state, it has SwiftUI go over everything on the map again, every one of the city's
/// lines, which takes it longer than a frame.
@Observable @MainActor
final class MapMotion {
    /// What the map shows, for keeping the buses over it in place.
    var shown: MKMapRect?
    /// Meters per point, for setting the route's lines side by side.
    var metersPerPoint: Double = 0
    /// The picker's circle's size on screen, in points across.
    var circleDiameter: CGFloat = 0
}

/// The open stop's lines on the home map, each in its color, the selected one on top; where they
/// share a track, side by side. And the stop.
struct RouteLayer: MapContent {
    let live: LiveRoute
    let city: City
    /// The map's zoom, for setting lines on a shared track side by side.
    let motion: MapMotion
    /// Stepping back, for another line picked over it.
    var dimmed = false
    let colorScheme: ColorScheme

    var body: some MapContent {
        ForEach(Array(live.tracks.enumerated().reversed()), id: \.offset) { _, track in
            let color = LiveRoute.color(of: track.lineID, in: city).legible(on: colorScheme).opacity(dimmed ? 0.35 : 1)
            ForEach(Array(track.segments.enumerated()), id: \.offset) { _, segment in
                if segment.count > 1 {
                    MapPolyline(coordinates: segment.map { $0.shifted(by: (Self.lineWidth + Self.lineGap) * motion.metersPerPoint) })
                        .stroke(color, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round))
                }
            }
        }
        if let selection = live.selection, let coordinate = live.selectedStop?.coordinate {
            // No title: the pill over the map names the stop, and buses arriving sit on the title,
            // which MapKit then keeps hiding and showing again as they move.
            Marker(selection.stopName, systemImage: "figure.wave", coordinate: coordinate)
                .tint(.blue)
                .annotationTitles(.hidden)
        }
    }

    private static let lineWidth: CGFloat = 4
    /// The room between lines side by side on a track, so their colors don't run together.
    private static let lineGap: CGFloat = 2.5
}

/// The buses over the map rather than in it: MapKit hides its labels under annotations, and with
/// buses moving that had street names flickering in and out wherever they passed. Each where it's
/// got to since it was last reported, at its pace along the route, placed where the map shows that
/// spot: as MapKit says, or while it can't (in the middle of a pinch), worked out from the area it
/// shows, so the buses don't go missing until it stops.
struct BusLayer: View {
    let live: LiveRoute
    let departures: [Departure]
    let proxy: MapProxy
    /// What the map shows as it moves, and its size.
    let motion: MapMotion
    let mapSize: CGSize

    var body: some View {
        // Read on every frame, not just when MapKit can't place a bus: it's what has them redrawn as the map
        // moves. Without it, they'd only catch up with a pan or pinch on their next glide, a second later.
        let shown = motion.shown
        ZStack(alignment: .topLeading) {
            if let selection = live.selection {
                ForEach(live.buses(in: departures), id: \.departure) { bus in
                    let place = live.glides[bus.departure]?.place(at: live.tick)
                    let coordinate = place?.coordinate ?? bus.vehicle.coordinate
                    if let point = proxy.convert(coordinate, to: .local) ?? estimatedPoint(of: coordinate, in: shown) {
                        BusMarker(bearing: place?.bearing ?? bus.vehicle.bearing, minutes: live.shortMinutes(bus.departure), isLive: bus.departure.isLive,
                                  line: selection.isMultiLine ? bus.departure.line : nil, vehicle: selection.vehicle,
                                  color: LiveRoute.color(of: bus.departure.line ?? selection.lineID, in: selection.city))
                            .position(point)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        // Only ever moving on their own as they glide: brought along with anything else animating (the map
        // closing, framing the route), they'd lag behind the map, which MapKit moves its own way.
        .transaction { if !$0[Gliding.self] { $0.animation = nil } }
    }

    /// The buses gliding along their routes, the one animation they go along with.
    struct Gliding: TransactionKey {
        static let defaultValue = false
    }

    private func estimatedPoint(of coordinate: CLLocationCoordinate2D, in shown: MKMapRect?) -> CGPoint? {
        guard let shown, shown.width > 0, shown.height > 0 else { return nil }
        let spot = MKMapPoint(coordinate)
        return CGPoint(x: (spot.x - shown.minX) / shown.width * mapSize.width,
                       y: (spot.y - shown.minY) / shown.height * mapSize.height)
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
struct Pair<A: Equatable, B: Equatable>: Equatable {
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
struct FollowsGesture: ViewModifier {
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
struct RefreshBar: View {
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


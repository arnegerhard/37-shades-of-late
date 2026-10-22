import MapKit
import SwiftUI

/// Every line in a city drawn on one map. Tap near a line to select it (lines running close
/// together are offered as chips). The selected line then shows each stop as a white arrow per
/// direction of travel: tap one to pick that stop and direction together, tap anywhere else to
/// let go of the line.
struct LineMapPicker: View {
    let city: City
    let onPick: (Selection) -> Void

    @State private var lines: [MapLine] = []
    @State private var paths: [String: [[CLLocationCoordinate2D]]] = [:]
    @State private var candidates: [MapLine] = []
    @State private var selectedID: String?
    @State private var directions: [Direction] = []
    @State private var arrows: [StopArrow] = []
    @State private var picked: StopArrow?
    @State private var heading: CLLocationDirection = 0
    @State private var error: String?
    @State private var position: MapCameraPosition
    @Environment(\.colorScheme) private var colorScheme

    init(city: City, onPick: @escaping (Selection) -> Void) {
        self.city = city
        self.onPick = onPick
        _position = State(initialValue: .region(city.region))
    }

    private var selected: MapLine? { candidates.first { $0.id == selectedID } }

    private var drawOrder: [MapLine] {
        lines.filter { $0.id != selectedID } + lines.filter { $0.id == selectedID }
    }

    var body: some View {
        MapReader { proxy in
            Map(position: $position) {
                // Selected line last, so it's drawn on top of the lines it shares streets with.
                ForEach(drawOrder) { line in
                    let isSelected = line.id == selectedID
                    let isCandidate = !isSelected && candidates.contains { $0.id == line.id }
                    // Many lines share a color (all Muni buses are blue), so only the selected line
                    // keeps full strength; nearby ones stay a bit clearer than the rest.
                    ForEach(Array((paths[line.id] ?? []).enumerated()), id: \.offset) { _, path in
                        MapPolyline(coordinates: path)
                            .stroke(line.mapColor.legible(on: colorScheme)
                                        .opacity(selectedID == nil || isSelected ? 1 : isCandidate ? 0.5 : 0.22),
                                    style: StrokeStyle(lineWidth: isSelected ? 7 : isCandidate ? 3.5 : 3,
                                                       lineCap: .round, lineJoin: .round))
                    }
                }

                ForEach(arrows) { arrow in
                    Annotation("", coordinate: arrow.position, anchor: .center) {
                        StopArrowMark(rotation: arrow.bearing - heading, isPicked: arrow.id == picked?.id,
                                      offset: arrow.screenOffset(heading: heading),
                                      color: selected?.mapColor ?? LineBadge.red)
                    }
                    .annotationTitles(.hidden)
                }
            }
            // A muted base map lets the route colors carry the picture.
            .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
            .onMapCameraChange(frequency: .continuous) { heading = $0.camera.heading }
            // Alongside the map's own gestures, which would otherwise swallow a plain tap.
            .simultaneousGesture(SpatialTapGesture().onEnded { tap in handleTap(at: tap.location, proxy: proxy) })
        }
        .safeAreaInset(edge: .bottom) { card }
        .overlay {
            if let error {
                ContentUnavailableView("Couldn't load the map", systemImage: "map", description: Text(error))
                    .background(.regularMaterial)
            } else if lines.isEmpty {
                ProgressView()
            }
        }
        .task(id: city) {
            lines = []
            paths = [:]
            deselect()
            error = nil
            position = .region(city.region)
            do {
                let loaded = try await TransitService.lineMap(in: city)
                paths = Dictionary(uniqueKeysWithValues: loaded.map { line in
                    (line.id, line.shapes.map { $0.compactMap { $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil } })
                })
                lines = loaded
            } catch {
                self.error = error.localizedDescription
            }
        }
        .task(id: selectedID) {
            directions = []
            arrows = []
            picked = nil
            guard let selected else { return }
            zoom(to: selected)
            guard let loaded = try? await TransitService.directions(for: selected.line, in: city), !Task.isCancelled else { return }
            directions = loaded
            withAnimation(.easeOut(duration: 0.25)) {
                arrows = StopArrow.arrows(for: loaded, lineShape: paths[selected.id] ?? [])
            }
        }
    }

    @ViewBuilder private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selected {
                if candidates.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(candidates) { line in
                                Button { selectedID = line.id } label: {
                                    LineBadge(line: line.id, font: .system(.subheadline, design: .rounded).weight(.heavy),
                                              color: line.mapColor, textColor: line.badgeTextColor)
                                        .opacity(line.id == selectedID ? 1 : 0.55)
                                        .padding(3)
                                        .overlay {
                                            if line.id == selectedID {
                                                RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.6), lineWidth: 1.5)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Line \(line.id), \(line.name)")
                            }
                        }
                    }
                }
                HStack(spacing: 12) {
                    LineBadge(line: selected.id, font: .system(.title3, design: .rounded).weight(.heavy),
                              color: selected.mapColor, textColor: selected.badgeTextColor)
                    VStack(alignment: .leading, spacing: 2) {
                        if let picked {
                            Text("To \(picked.direction.destination)").font(.headline).lineLimit(1)
                            Text(picked.stop.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            Text(selected.name).font(.headline).lineLimit(1)
                            Text(arrows.isEmpty ? "Loading stops…" : "Tap an arrow: that stop, that direction.")
                                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                    if let picked {
                        Button("Choose") { choose(picked) }
                            .font(.subheadline.weight(.semibold))
                            .buttonStyle(.borderedProminent)
                            .tint(LineBadge.red)
                    } else {
                        // The list is still there for anyone who'd rather read street names.
                        NavigationLink(value: selected.line) {
                            Image(systemName: "list.bullet").accessibilityLabel("Stop list")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else {
                Label(lines.isEmpty ? "Loading lines…" : "Tap a line on the map to pick it.", systemImage: "hand.tap")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding()
    }

    /// With a line selected: an arrow within a fingertip picks that stop and direction (tapping it
    /// again chooses it); anywhere else lets go of the line. Without one: select the nearest line.
    private func handleTap(at point: CGPoint, proxy: MapProxy) {
        guard selectedID == nil else {
            let hit = arrows
                .compactMap { arrow -> (StopArrow, CGFloat)? in
                    // Measure to where the arrow is drawn, not to the stop it belongs to.
                    guard let stop = proxy.convert(arrow.position, to: .local) else { return nil }
                    let shift = arrow.screenOffset(heading: heading)
                    let spot = CGPoint(x: stop.x + shift.width, y: stop.y + shift.height)
                    let distance = hypot(spot.x - point.x, spot.y - point.y)
                    return distance <= 24 ? (arrow, distance) : nil
                }
                .min { $0.1 < $1.1 }?.0
            if let hit {
                if hit.id == picked?.id { choose(hit) } else { withAnimation(.snappy(duration: 0.2)) { picked = hit } }
            } else {
                withAnimation(.snappy(duration: 0.25)) { deselect() }
            }
            return
        }
        selectLine(near: point, proxy: proxy)
    }

    /// Lines within about a fingertip (24 pt) of the tap, nearest first.
    private func selectLine(near point: CGPoint, proxy: MapProxy) {
        guard let tap = proxy.convert(point, from: .local),
              let edge = proxy.convert(CGPoint(x: point.x + 24, y: point.y), from: .local)
        else { return }
        let reach = meters(tap, edge)
        let nearby = lines
            .compactMap { line -> (MapLine, Double)? in
                let distance = (paths[line.id] ?? []).map { distanceToPath(tap, $0) }.min() ?? .infinity
                return distance <= reach ? (line, distance) : nil
            }
            .sorted { $0.1 < $1.1 }
            .prefix(8)
            .map(\.0)
        withAnimation(.snappy(duration: 0.25)) {
            candidates = Array(nearby)
            selectedID = nearby.first?.id
        }
    }

    private func deselect() {
        candidates = []
        selectedID = nil
        directions = []
        arrows = []
        picked = nil
    }

    private func choose(_ arrow: StopArrow) {
        guard let selected else { return }
        onPick(Selection(
            lineID: selected.id, lineName: selected.name, directionID: arrow.direction.id,
            destination: arrow.direction.destination, stopCode: arrow.stop.code, stopName: arrow.stop.name,
            city: city))
    }

    /// Frame the whole line, so its arrows are big enough to tap after a little zooming.
    private func zoom(to line: MapLine) {
        let points = (paths[line.id] ?? []).flatMap { $0 }.map(MKMapPoint.init)
        guard let first = points.first else { return }
        var rect = MKMapRect(origin: first, size: MKMapSize(width: 0, height: 0))
        for point in points.dropFirst() { rect = rect.union(MKMapRect(origin: point, size: MKMapSize(width: 0, height: 0))) }
        let pad = max(rect.width, rect.height) * 0.12
        withAnimation(.smooth(duration: 0.6)) {
            position = .rect(rect.insetBy(dx: -pad, dy: -pad))
        }
    }
}

/// One stop in one direction of travel, drawn as an arrow pointing the way the bus goes from there.
struct StopArrow: Identifiable, Equatable {
    let direction: Direction
    let stop: Stop
    let position: CLLocationCoordinate2D
    /// Degrees clockwise from north.
    let bearing: Double

    var id: String { "\(direction.id)|\(stop.code)" }

    /// Drawn this far (in points) to the right of travel, the side of the street the bus stops on.
    /// Separating in screen points rather than meters keeps a stop's two directions apart at any
    /// zoom, so each arrow can be tapped on its own.
    static let sideOffset: CGFloat = 13

    /// Where to draw the arrow relative to its stop, on a map rotated by `heading`.
    func screenOffset(heading: Double) -> CGSize {
        let right = (bearing + 90 - heading) * .pi / 180
        return CGSize(width: Self.sideOffset * sin(right), height: -Self.sideOffset * cos(right))
    }

    static func == (a: StopArrow, b: StopArrow) -> Bool { a.id == b.id }

    /// Arrows for every stop of every direction. Each arrow follows the street at its stop: the
    /// route shape's segment nearest the stop (the direction's own shape where the city provides
    /// one, else the line's), turned around if it points against the direction of travel. Where
    /// no shape runs past a stop (a one-way street the other direction doesn't use), the arrow
    /// points from the previous stop to the next instead. Lines that zigzag thus get arrows that
    /// follow each street rather than cutting corners toward the next stop.
    static func arrows(for directions: [Direction], lineShape: [[CLLocationCoordinate2D]]) -> [StopArrow] {
        directions.flatMap { direction -> [StopArrow] in
            let ownShape = (direction.shapes ?? []).map { segment in
                segment.compactMap { $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil }
            }
            let shape = ownShape.isEmpty ? lineShape : ownShape
            let stops = direction.stops.filter { $0.coordinate != nil }
            return stops.indices.compactMap { i -> StopArrow? in
                guard let here = stops[i].coordinate else { return nil }
                let previous = i > 0 ? stops[i - 1].coordinate! : here
                let next = i < stops.count - 1 ? stops[i + 1].coordinate! : here
                // The way the bus is heading here: how it arrives and how it leaves, blended. At a
                // corner stop (the 37 at 14th & Church) the next stop alone can lie: the outbound bus
                // arrives eastbound on 14th, then turns south, so previous-to-next points nearly
                // south and a westbound street would wrongly look closer than an eastbound one.
                let travel = blendedBearing(arriving: bearingBetween(previous, here, ifSame: nil),
                                            leaving: bearingBetween(here, next, ifSame: nil))
                    ?? bearingBetween(previous, next)
                var bearing = travel
                if let street = streetBearing(at: here, along: shape), meters(here, street.point) < 35 {
                    // A direction's own shape is drawn in its order of travel; the line's shared shape
                    // may run the other way, so trust the stop sequence for which way to point.
                    bearing = ownShape.isEmpty && angleBetween(street.bearing, travel) > 90
                        ? (street.bearing + 180).truncatingRemainder(dividingBy: 360)
                        : street.bearing
                }
                return StopArrow(direction: direction, stop: stops[i], position: here,
                                 bearing: bearing)
            }
        }
    }
}

/// White arrow with a dark rim, readable on any map; the picked one grows and takes the line's color.
private struct StopArrowMark: View {
    let rotation: Double
    let isPicked: Bool
    let offset: CGSize
    let color: Color

    var body: some View {
        ZStack {
            if isPicked {
                Circle().fill(.white).frame(width: 36, height: 36).shadow(color: .black.opacity(0.5), radius: 3)
            }
            Image(systemName: "location.north.fill")
                .font(.system(size: isPicked ? 20 : 13, weight: .bold))
                .foregroundStyle(isPicked ? color : .white)
                .shadow(color: .black.opacity(isPicked ? 0 : 0.9), radius: 1.2)
                .rotationEffect(.degrees(rotation))
        }
        .offset(offset)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension MapLine {
    /// The agency's official color, or Muni red where it doesn't publish one.
    var mapColor: Color { Color(hex: color) ?? LineBadge.red }
    var badgeTextColor: Color { Color(hex: textColor) ?? .white }
}

extension Color {
    /// The same hue, brightened on dark maps (Muni's navy blue nearly vanishes there) and darkened
    /// on light maps when it's too pale, so every line stands out from the streets.
    func legible(on scheme: ColorScheme) -> Color {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(self).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else { return self }
        // Greys (Muni's owl and bus-substitute routes) stay a quiet mid grey in both modes.
        if saturation < 0.15 { return Color(white: scheme == .dark ? 0.62 : 0.5, opacity: alpha) }
        if scheme == .dark {
            // Lift dark colors and soften their saturation a little so they glow instead of looking muddy.
            return Color(hue: hue, saturation: brightness < 0.8 ? min(saturation, 0.85) : saturation,
                         brightness: max(brightness, 0.92), opacity: alpha)
        }
        return Color(hue: hue, saturation: max(saturation, 0.55), brightness: min(brightness, 0.78), opacity: alpha)
    }
}

extension City {
    /// The area the line map opens on.
    var region: MKCoordinateRegion {
        switch self {
        case .sf:
            MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 37.765, longitude: -122.44),
                               span: MKCoordinateSpan(latitudeDelta: 0.13, longitudeDelta: 0.13))
        case .seattle:
            MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 47.62, longitude: -122.32),
                               span: MKCoordinateSpan(latitudeDelta: 0.22, longitudeDelta: 0.22))
        }
    }
}

// MARK: - Geometry in meters (flat-earth, fine at city scale)

/// Degrees clockwise from north, from `a` to `b`.
private func bearingBetween(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
    let x = (b.longitude - a.longitude) * 111_320 * cos(a.latitude * .pi / 180)
    let y = (b.latitude - a.latitude) * 110_540
    let degrees = atan2(x, y) * 180 / .pi
    return degrees < 0 ? degrees + 360 : degrees
}

/// Like `bearingBetween`, but `ifSame` when the two points coincide (a line's first or last stop).
private func bearingBetween(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, ifSame: Double?) -> Double? {
    a.latitude == b.latitude && a.longitude == b.longitude ? ifSame : bearingBetween(a, b)
}

/// The average of two headings (as unit vectors), or whichever one exists.
private func blendedBearing(arriving: Double?, leaving: Double?) -> Double? {
    guard let arriving else { return leaving }
    guard let leaving else { return arriving }
    let (a, b) = (arriving * .pi / 180, leaving * .pi / 180)
    let (x, y) = (sin(a) + sin(b), cos(a) + cos(b))
    guard x * x + y * y > 1e-6 else { return arriving }  // a U-turn: go with how it arrived
    let degrees = atan2(x, y) * 180 / .pi
    return degrees < 0 ? degrees + 360 : degrees
}

/// Smallest angle between two bearings, 0...180.
private func angleBetween(_ a: Double, _ b: Double) -> Double {
    let d = abs(a - b).truncatingRemainder(dividingBy: 360)
    return d > 180 ? 360 - d : d
}

/// The shape segment closest to `point`: its bearing (in drawing order) and the nearest point on it.
private func streetBearing(at point: CLLocationCoordinate2D, along shape: [[CLLocationCoordinate2D]])
    -> (bearing: Double, point: CLLocationCoordinate2D)? {
    var best: (distance: Double, bearing: Double, point: CLLocationCoordinate2D)?
    let lonScale = 111_320 * cos(point.latitude * .pi / 180)
    for path in shape {
        for (a, b) in zip(path, path.dropFirst()) where a.latitude != b.latitude || a.longitude != b.longitude {
            let p = ((a.longitude - point.longitude) * lonScale, (a.latitude - point.latitude) * 110_540)
            let q = ((b.longitude - point.longitude) * lonScale, (b.latitude - point.latitude) * 110_540)
            let (dx, dy) = (q.0 - p.0, q.1 - p.1)
            let t = max(0, min(1, -(p.0 * dx + p.1 * dy) / (dx * dx + dy * dy)))
            let (x, y) = (p.0 + t * dx, p.1 + t * dy)
            let distance = (x * x + y * y).squareRoot()
            if distance < best?.distance ?? .infinity {
                let nearest = CLLocationCoordinate2D(latitude: point.latitude + y / 110_540, longitude: point.longitude + x / lonScale)
                best = (distance, bearingBetween(a, b), nearest)
            }
        }
    }
    return best.map { ($0.bearing, $0.point) }
}


private func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
    let x = (b.longitude - a.longitude) * 111_320 * cos(a.latitude * .pi / 180)
    let y = (b.latitude - a.latitude) * 110_540
    return (x * x + y * y).squareRoot()
}

private func distanceToPath(_ point: CLLocationCoordinate2D, _ path: [CLLocationCoordinate2D]) -> Double {
    let lonScale = 111_320 * cos(point.latitude * .pi / 180)
    func local(_ c: CLLocationCoordinate2D) -> (x: Double, y: Double) {
        ((c.longitude - point.longitude) * lonScale, (c.latitude - point.latitude) * 110_540)
    }
    var best = Double.infinity
    for (a, b) in zip(path, path.dropFirst()) {
        let (p, q) = (local(a), local(b))
        let (dx, dy) = (q.x - p.x, q.y - p.y)
        let length = dx * dx + dy * dy
        let t = length > 0 ? max(0, min(1, -(p.x * dx + p.y * dy) / length)) : 0
        let (x, y) = (p.x + t * dx, p.y + t * dy)
        best = min(best, (x * x + y * y).squareRoot())
    }
    return best
}

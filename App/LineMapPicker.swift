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
    /// Other lines serving the picked stop, and which of them the user also wants to count.
    @State private var otherLines: [StopLine] = []
    @State private var alsoIDs: Set<String> = []
    /// The stops of the lines added with "Also fine with", drawn as dots in their color.
    @State private var alsoStops: [String: [CLLocationCoordinate2D]] = [:]
    /// The area the map showed when it last came to rest, and before the first "Also fine with" line
    /// zoomed it out, so removing the added lines brings the user back to the spot they zoomed in to.
    /// (An area, not a camera: a camera's center ignores the card over the bottom of the map.)
    @State private var visibleRect: MKMapRect?
    @State private var cameraBeforeAlso: MapCameraPosition?
    @State private var heading: CLLocationDirection = 0
    /// Where each line's name badge may go (worked out once per line map), and the badges shown now.
    @State private var labelSpots: [String: [LabelSpot]] = [:]
    @State private var labels: [LineLabel] = []
    /// The map's frame, which stops at the header above and the card below.
    @State private var mapSize: CGSize = .zero
    @State private var error: String?
    @State private var position: MapCameraPosition
    @Environment(\.colorScheme) private var colorScheme

    init(city: City, onPick: @escaping (Selection) -> Void) {
        self.city = city
        self.onPick = onPick
        _position = State(initialValue: .region(city.region))
    }

    private var selected: MapLine? { candidates.first { $0.id == selectedID } }

    /// The lines added with "Also fine with" (their map line IDs).
    private var alsoLineIDs: Set<String> {
        Set(otherLines.filter { alsoIDs.contains($0.id) }.map(\.line))
    }

    /// The other stops the added lines are caught at, to walk to.
    private var walkStops: [StopLine] {
        otherLines.filter { alsoIDs.contains($0.id) && $0.isNearby && $0.lat != nil && $0.lon != nil }
    }

    private var drawOrder: [MapLine] {
        let also = alsoLineIDs
        return lines.filter { $0.id != selectedID && !also.contains($0.id) }
            + lines.filter { also.contains($0.id) }
            + lines.filter { $0.id == selectedID }
    }

    var body: some View {
        MapReader { proxy in
            Map(position: $position) {
                // Selected line last, so it's drawn on top of the lines it shares streets with.
                ForEach(drawOrder) { line in
                    let isSelected = line.id == selectedID || alsoLineIDs.contains(line.id)
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

                // Line names. While a line is picked they step back like the other lines do.
                ForEach(labels) { label in
                    if let line = lines.first(where: { $0.id == label.lineID }) {
                        Annotation("", coordinate: label.coordinate, anchor: .center) {
                            LineBadge(line: line.id, font: .system(size: 12, weight: .heavy, design: .rounded),
                                      color: line.mapColor.legible(on: colorScheme), textColor: line.badgeTextColor)
                                .fixedSize()
                                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                                .opacity(selectedID == nil ? 1 : 0.35)
                                .allowsHitTesting(false)
                        }
                        .annotationTitles(.hidden)
                    }
                }

                ForEach(alsoStops.sorted { $0.key < $1.key }, id: \.key) { lineID, stops in
                    let color = (lines.first { $0.id == lineID }?.mapColor ?? LineBadge.red).legible(on: colorScheme)
                    ForEach(Array(stops.enumerated()), id: \.offset) { _, stop in
                        Annotation("", coordinate: stop, anchor: .center) {
                            Circle().fill(.white).stroke(color, lineWidth: 2).frame(width: 8, height: 8)
                        }
                        .annotationTitles(.hidden)
                    }
                }

                ForEach(walkStops) { other in
                    let color = (lines.first { $0.id == other.line }?.mapColor ?? LineBadge.red).legible(on: colorScheme)
                    Annotation(other.stopName ?? "", coordinate: CLLocationCoordinate2D(latitude: other.lat!, longitude: other.lon!), anchor: .center) {
                        Image(systemName: "figure.walk")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(color, in: Circle())
                            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                    }
                    .annotationTitles(.hidden)
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
            .onMapCameraChange(frequency: .onEnd) {
                visibleRect = $0.rect
                relabel(proxy)
            }
            .onGeometryChange(for: CGSize.self, of: \.size) { mapSize = $0 }
            .task(id: lines.count) {
                // Off the main thread: a city's worth of lines takes a moment.
                let paths = paths
                let spots = await Task.detached(priority: .userInitiated) { LineLabels.spots(for: paths) }.value
                guard !Task.isCancelled else { return }
                labelSpots = spots
                relabel(proxy)
            }
            .onChange(of: selectedID) { relabel(proxy) }
            .onChange(of: alsoLineIDs) { relabel(proxy) }
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
            labelSpots = [:]
            labels = []
            deselect()
            error = nil
            position = .region(city.region)
            // Instantly from the device (or the app's built-in snapshot), then quietly swap in newer
            // data if the proxy has it; that's checked at most once a day.
            show(TransitService.cachedLineMap(in: city))
            if lines.isEmpty { error = "No line data yet. Check your connection." }
            if let newer = await TransitService.refreshedLineMap(in: city), !Task.isCancelled {
                show(newer)
                error = nil
            }
        }
        .task(id: picked?.id) {
            otherLines = []
            alsoIDs = []
            // Another stop: the map stays where it is, wherever that is now.
            cameraBeforeAlso = nil
            guard let picked, let selected else { return }
            // The lines here plus those a short walk away going the same way, nearest first.
            var found = try? await TransitService.nearbyLines(picked.stop.code, direction: picked.direction.id, in: city)
            if found == nil { found = try? await TransitService.linesAtStop(picked.stop.code, in: city) }
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.25)) {
                otherLines = (found ?? []).filter { $0.line != selected.id }
            }
        }
        .task(id: alsoLineIDs) {
            // The stops of each added line, in the direction it goes from the picked stop.
            let wanted = otherLines.filter { alsoIDs.contains($0.id) }
            var found: [String: [CLLocationCoordinate2D]] = [:]
            for other in wanted {
                let line = Line(id: other.line, name: "", mode: "bus")
                var loaded = TransitService.cachedDirections(for: line, in: city)
                if loaded == nil { loaded = try? await TransitService.directions(for: line, in: city) }
                guard !Task.isCancelled else { return }
                // The direction that serves its stop; a nearby Seattle stop doesn't say which that is.
                let stop = other.stop ?? picked?.stop.code
                let direction = loaded?.first { $0.id == other.direction && $0.stops.contains { $0.code == stop } }
                    ?? loaded?.first { $0.stops.contains { $0.code == stop } }
                    ?? loaded?.first { $0.id == other.direction } ?? loaded?.first
                found[other.line] = direction?.stops.compactMap(\.coordinate) ?? []
            }
            withAnimation(.easeOut(duration: 0.25)) { alsoStops = found }
        }
        .task(id: selectedID) {
            // The map stays put: the user may have zoomed in to their stop before picking the line.
            directions = []
            arrows = []
            picked = nil
            guard let selected else { return }
            // Stops seen before are on the device already; others need one download.
            var loaded = TransitService.cachedDirections(for: selected.line, in: city)
            if loaded == nil { loaded = try? await TransitService.directions(for: selected.line, in: city) }
            guard let loaded, !Task.isCancelled else { return }
            directions = loaded
            withAnimation(.easeOut(duration: 0.25)) {
                arrows = StopArrow.arrows(for: loaded, lineShape: paths[selected.id] ?? [])
            }
        }
    }

    @ViewBuilder private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selected {
                if picked != nil, !otherLines.isEmpty {
                    alsoTake
                } else if candidates.count > 1 {
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

    /// "Also take" chips: the other lines at the picked stop, which the user can add so the stop
    /// counts whichever comes first (the K, L and M toward downtown at Castro).
    private var alsoTake: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Also fine with").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(otherLines) { other in
                        let on = alsoIDs.contains(other.id)
                        let mapLine = lines.first { $0.id == other.line }
                        Button { toggleAlso(other) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: on ? "checkmark.circle.fill" : "plus.circle")
                                    .font(.caption)
                                LineBadge(line: other.line, font: .system(.subheadline, design: .rounded).weight(.heavy),
                                          color: mapLine?.mapColor ?? LineBadge.red, textColor: mapLine?.badgeTextColor ?? .white)
                                if other.isNearby {
                                    // A short walk to another stop.
                                    Text(walkLabel(other))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(on ? Color.primary.opacity(0.15) : .clear, in: Capsule())
                            .opacity(on ? 1 : 0.7)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(other.isNearby
                            ? "Also take line \(other.line), \(walkLabel(other)) away at \(other.stopName ?? "another stop")"
                            : "Also take line \(other.line) to \(other.destination)")
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
        }
    }

    /// "80 m", to the nearest 10 m.
    private func walkLabel(_ line: StopLine) -> String {
        "\(max(10, Int((Double(line.distance ?? 0) / 10).rounded()) * 10)) m"
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

    /// Places the line badges for what the map shows now.
    private func relabel(_ proxy: MapProxy) {
        guard let visibleRect, mapSize.width > 0, !labelSpots.isEmpty else { return }
        let metersPerPoint = visibleRect.width * MKMetersPerMapPointAtLatitude(visibleRect.origin.coordinate.latitude) / mapSize.width
        // Clear of the edges, so no badge is cut off.
        let bounds = CGRect(origin: .zero, size: mapSize).insetBy(dx: 8, dy: 6)
        let placed = LineLabels.place(
            lines: lines, spots: labelSpots, excluding: alsoLineIDs.union([selectedID].compactMap { $0 }),
            visible: visibleRect, bounds: bounds, metersPerPoint: metersPerPoint,
            convert: { proxy.convert($0, to: .local) })
        withAnimation(.easeOut(duration: 0.2)) { labels = placed }
    }

    private func show(_ loaded: [MapLine]) {
        guard !loaded.isEmpty else { return }
        paths = Dictionary(uniqueKeysWithValues: loaded.map { line in
            (line.id, line.shapes.map { $0.compactMap { $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil } })
        })
        lines = loaded
        // A refresh may have dropped the selected line (a service change); let go of it then.
        if let selectedID, !loaded.contains(where: { $0.id == selectedID }) { deselect() }
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
        // Only lines still offered for this stop (the chips reset when the arrow changes).
        let also = otherLines.filter { alsoIDs.contains($0.id) }
            .map { Selection.OtherLine(lineID: $0.line, directionID: $0.direction, stopCode: $0.isNearby ? $0.stop : nil) }
        onPick(Selection(
            lineID: selected.id, lineName: selected.name, directionID: arrow.direction.id,
            destination: arrow.direction.destination, stopCode: arrow.stop.code, stopName: arrow.stop.name,
            city: city, also: also))
    }

    /// Adding a line zooms out to show all of it and its stops; removing the last one goes back to
    /// exactly where the map was before.
    private func toggleAlso(_ other: StopLine) {
        let wasEmpty = alsoIDs.isEmpty
        withAnimation(.snappy(duration: 0.2)) {
            if alsoIDs.contains(other.id) { alsoIDs.remove(other.id) } else { alsoIDs.insert(other.id) }
        }
        if alsoIDs.isEmpty {
            if let cameraBeforeAlso {
                withAnimation(.smooth(duration: 0.6)) { position = cameraBeforeAlso }
            }
            cameraBeforeAlso = nil
        } else {
            // Before the map has moved at all, it still shows the position it opened with.
            if wasEmpty { cameraBeforeAlso = visibleRect.map { .rect($0) } ?? position }
            frame(alsoLineIDs, including: picked?.position)
        }
    }

    /// Frame whole lines (and a point, like the picked stop), with a little room around them.
    private func frame(_ lineIDs: Set<String>, including extra: CLLocationCoordinate2D?) {
        let points = (lineIDs.flatMap { paths[$0] ?? [] }.flatMap { $0 } + [extra].compactMap { $0 }).map(MKMapPoint.init)
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

/// A spot on a line where its name badge may go, and how much room there is around it.
struct LabelSpot {
    let coordinate: CLLocationCoordinate2D
    let point: MKMapPoint
    /// Meters to the nearest other line, up to `LineLabels.maxRoom`.
    let room: Double
}

/// A line's name badge, placed on the map.
struct LineLabel: Identifiable, Equatable {
    let lineID: String
    let spot: Int
    let coordinate: CLLocationCoordinate2D

    var id: String { "\(lineID)|\(spot)" }

    static func == (a: LineLabel, b: LineLabel) -> Bool { a.id == b.id }
}

/// Line name badges, like a transit map's: at city scale only the backbone (rail, cable cars, rapid
/// lines), every line as you zoom in, repeated along each line when close. Each badge goes where its
/// line runs alone, and badges never overlap one another.
enum LineLabels {
    static let maxRoom = 400.0
    /// One spot to consider every 150 m along each line.
    private static let spacing = 150.0

    /// 0: the backbone, labeled at any zoom. 1: regular lines. 2: express, owl and shuttle lines.
    static func tier(of line: MapLine) -> Int {
        let id = line.id
        if line.mode != "bus" { return 0 }
        if id.hasSuffix("R"), id.dropLast().allSatisfy(\.isNumber) { return 0 }   // Muni's Rapid lines
        if id.count == 6, id.hasSuffix(" Line") { return 0 }                      // RapidRide A–H
        if id.hasSuffix("X") || id.contains("OWL") || id.hasSuffix("BUS") || id.contains("Shuttle") || id == "Easy Loop" {
            return 2
        }
        return 1
    }

    /// The candidate spots along every line. Runs once per line map, off the main thread.
    static func spots(for paths: [String: [[CLLocationCoordinate2D]]]) -> [String: [LabelSpot]] {
        guard let anywhere = paths.values.lazy.flatMap({ $0 }).first?.first else { return [:] }
        let perMeter = 1 / MKMetersPerMapPointAtLatitude(anywhere.latitude)
        let cell = maxRoom * perMeter

        // Every route segment, filed in a grid of `maxRoom` cells so a spot only looks at its neighbors.
        var segments: [(line: String, a: MKMapPoint, b: MKMapPoint)] = []
        var grid: [Int64: [Int]] = [:]
        func key(_ x: Int, _ y: Int) -> Int64 { Int64(x) << 32 | Int64(UInt32(bitPattern: Int32(y))) }
        for (id, lines) in paths {
            for path in lines {
                for (a, b) in zip(path, path.dropFirst()) {
                    let (p, q) = (MKMapPoint(a), MKMapPoint(b))
                    segments.append((id, p, q))
                    for x in Int(floor(min(p.x, q.x) / cell))...Int(floor(max(p.x, q.x) / cell)) {
                        for y in Int(floor(min(p.y, q.y) / cell))...Int(floor(max(p.y, q.y) / cell)) {
                            grid[key(x, y), default: []].append(segments.count - 1)
                        }
                    }
                }
            }
        }

        func room(at point: MKMapPoint, besides line: String) -> Double {
            let (cx, cy) = (Int(floor(point.x / cell)), Int(floor(point.y / cell)))
            var nearest = cell
            for x in cx - 1...cx + 1 {
                for y in cy - 1...cy + 1 {
                    for index in grid[key(x, y)] ?? [] where segments[index].line != line {
                        nearest = min(nearest, distance(from: point, to: segments[index].a, segments[index].b))
                    }
                }
            }
            return min(nearest / perMeter, maxRoom)
        }

        let step = spacing * perMeter
        var result: [String: [LabelSpot]] = [:]
        for (id, lines) in paths {
            var spots: [LabelSpot] = []
            for path in lines {
                var next = step / 2
                for (a, b) in zip(path, path.dropFirst()) {
                    let (p, q) = (MKMapPoint(a), MKMapPoint(b))
                    let length = hypot(q.x - p.x, q.y - p.y)
                    while next <= length {
                        let point = MKMapPoint(x: p.x + (q.x - p.x) * next / length, y: p.y + (q.y - p.y) * next / length)
                        spots.append(LabelSpot(coordinate: point.coordinate, point: point, room: room(at: point, besides: id)))
                        next += step
                    }
                    next -= length
                }
            }
            result[id] = spots
        }
        return result
    }

    private static func distance(from p: MKMapPoint, to a: MKMapPoint, _ b: MKMapPoint) -> Double {
        let (dx, dy) = (b.x - a.x, b.y - a.y)
        let length = dx * dx + dy * dy
        let t = length > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length)) : 0
        return hypot(a.x + t * dx - p.x, a.y + t * dy - p.y)
    }

    /// The badges to show in `bounds` (screen points) at `metersPerPoint`: lines in tier order, each
    /// at its roomiest free spot, those with the fewest spots on screen first so they aren't crowded out.
    static func place(lines: [MapLine], spots: [String: [LabelSpot]], excluding: Set<String>,
                      visible: MKMapRect, bounds: CGRect, metersPerPoint: Double,
                      convert: (CLLocationCoordinate2D) -> CGPoint?) -> [LineLabel] {
        let maxTier = metersPerPoint < 4.5 ? 2 : metersPerPoint < 22 ? 1 : 0
        let repeats = metersPerPoint < 9
        let candidates = lines.compactMap { line -> (line: MapLine, tier: Int, spots: [(index: Int, spot: LabelSpot, at: CGPoint, score: Double)])? in
            let tier = tier(of: line)
            guard tier <= maxTier, !excluding.contains(line.id) else { return nil }
            let onScreen = (spots[line.id] ?? []).enumerated().compactMap { index, spot -> (Int, LabelSpot, CGPoint, Double)? in
                guard visible.contains(spot.point), let at = convert(spot.coordinate), bounds.contains(at) else { return nil }
                // Room in screen points, capped: past a badge's height, more room doesn't matter.
                return (index, spot, at, min(spot.room / metersPerPoint, 30))
            }
            return onScreen.isEmpty ? nil : (line, tier, onScreen.sorted { $0.3 > $1.3 })
        }
        .sorted { ($0.tier, $0.spots.count) < ($1.tier, $1.spots.count) }

        // The Apple Maps logo and Legal link sit in the bottom-left corner.
        var taken = [CGRect(x: bounds.minX - 8, y: bounds.maxY - 34, width: 150, height: 40)]
        var labels: [LineLabel] = []
        for (line, _, spots) in candidates {
            let size = CGSize(width: 14 + 7.5 * Double(line.id.count), height: 20)
            var mine: [CGPoint] = []
            for spot in spots {
                if mine.contains(where: { hypot($0.x - spot.at.x, $0.y - spot.at.y) < 260 }) { continue }
                let box = CGRect(x: spot.at.x - size.width / 2, y: spot.at.y - size.height / 2,
                                 width: size.width, height: size.height).insetBy(dx: -4, dy: -3)
                if !bounds.contains(box) || taken.contains(where: { $0.intersects(box) }) { continue }
                taken.append(box)
                mine.append(spot.at)
                labels.append(LineLabel(lineID: line.id, spot: spot.index, coordinate: spot.spot.coordinate))
                if !repeats || mine.count == 3 { break }
            }
            if labels.count >= 60 { break }
        }
        return labels
    }
}

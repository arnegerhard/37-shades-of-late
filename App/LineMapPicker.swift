import MapKit
import SwiftUI

/// Every line in a city drawn on one map. Zoomed out, where a fingertip covers several lines, a tap
/// zooms in on where it landed, just far enough for the stops there to show. Tap a line where you catch it: that selects the line
/// (lines running close together are offered as chips) and its stop nearest the tap. The card then
/// offers the ways it goes from there, each with an arrow that points like the map, where it heads,
/// its next stop and its live minutes; the same arrows sit at the stop on the map. Tap along the
/// line for another stop, anywhere else to let go of it. Zoomed in to a neighborhood, every stop shows
/// as a white dot; tapping one selects a line that stops there (the others as chips) and that stop.
struct LineMapPicker: View {
    let city: City
    let onPick: (Selection) -> Void

    @State private var lines: [MapLine] = []
    @State private var paths: [String: [[CLLocationCoordinate2D]]] = [:]
    /// Bumped whenever `paths` changes, so the lines' layer can tell it's unchanged cheaply.
    @State private var pathsVersion = 0
    @State private var candidates: [MapLine] = []
    @State private var selectedID: String?
    @State private var directions: [Direction] = []
    @State private var arrows: [StopArrow] = []
    /// The selected line's stops as dots, one per corner (both directions' stops near each other).
    @State private var stopDots: [StopDot] = []
    /// Where the last tap on a line landed, so the line it selects (or a chip) opens on the stop there.
    @State private var tapCoordinate: CLLocationCoordinate2D?
    /// The stop picked on the selected line: one arrow per direction there.
    @State private var corner: [StopArrow] = []
    /// The line `corner`'s arrows are drawn in.
    @State private var cornerLine: MapLine?
    /// The arrows of the stop just let go of, fading out as the new stop's fade in, in their line.
    @State private var leaving: (arrows: [StopArrow], line: MapLine?) = ([], nil)
    /// The next departures each of those directions has, by arrow id.
    @State private var cornerTimes: [String: [Departure]] = [:]
    @State private var picked: StopArrow?
    /// Fetching the stops of a line about to be selected.
    @State private var lineLoad: Task<Void, Never>?
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
    /// Badges just taken off, kept on the map while they fade out, until the given time.
    @State private var leavingLabels: [String: (label: LineLabel, until: Date)] = [:]
    /// When the badges were last placed during a camera move, to do it only a few times a second.
    @State private var liveRelabelAt: Date = .distantPast
    /// The map's frame, which stops at the header above and the card below.
    @State private var mapSize: CGSize = .zero
    /// The room kept for the card under the map (see the card's inset).
    @State private var cardRoom: CGFloat = 0
    /// How zoomed in the map is; stop dots show once stops are a fingertip apart.
    @State private var metersPerPoint: Double = .infinity
    /// Every stop in the city, and those in view once zoomed in far enough to show them.
    @State private var allStops: [MapStop] = []
    @State private var shownStops: [MapStop] = []
    @State private var error: String?
    /// The lines and their badges blend in once the map is up (after it zooms out of the home screen's).
    @State private var fade: Double = 0
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

    /// New York's buses, which outnumber its trains more than ten to one.
    private func isBackground(_ line: MapLine) -> Bool {
        city == .nyc && line.mode == "bus"
    }

    private var drawOrder: [MapLine] {
        let also = alsoLineIDs
        // In New York the buses go underneath, so the trains stay readable on top of them.
        let rest = lines.filter { $0.id != selectedID && !also.contains($0.id) }
        return rest.filter(isBackground) + rest.filter { !isBackground($0) }
            + lines.filter { also.contains($0.id) }
            + lines.filter { $0.id == selectedID }
    }

    var body: some View {
        MapReader { proxy in
            Map(position: $position) {
                // Selected line last, so it's drawn on top of the lines it shares streets with.
                LineLayer(lines: drawOrder, paths: paths, pathsVersion: pathsVersion, selectedID: selectedID,
                          alsoLineIDs: alsoLineIDs, candidateIDs: Set(candidates.map(\.id)),
                          colorScheme: colorScheme, isBackground: isBackground, fade: fade)

                // Line names. While a line is picked they step back like the other lines do.
                ForEach(labels + leavingLabels.values.map(\.label).sorted { $0.id < $1.id }) { label in
                    if let line = lines.first(where: { $0.id == label.lineID }) {
                        Annotation("", coordinate: label.coordinate, anchor: .center) {
                            FadingBadge(leaving: leavingLabels[label.id] != nil) {
                                LineBadge(line: line.id, font: .system(size: 12, weight: .heavy, design: .rounded),
                                          color: line.mapColor.legible(on: colorScheme), textColor: line.badgeTextColor)
                                    .fixedSize()
                                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                            }
                            .opacity((selectedID == nil ? 1 : 0.35) * fade)
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

                // Every stop around, underneath the selected line's own.
                ForEach(shownStops) { stop in
                    Annotation("", coordinate: stop.coordinate, anchor: .center) {
                        Circle().fill(.white).stroke(.gray, lineWidth: 1.5).frame(width: 8, height: 8)
                            .allowsHitTesting(false)
                    }
                    .annotationTitles(.hidden)
                }

                // The selected line's stops, once zoomed in far enough to tell them apart.
                if metersPerPoint < Self.dotsBelowMetersPerPoint {
                    let color = (selected?.mapColor ?? LineBadge.red).legible(on: colorScheme)
                    // By place, so switching lines fades dots out and in rather than sliding them across.
                    ForEach(stopDots, id: \.self) { dot in
                        Annotation("", coordinate: dot.coordinate, anchor: .center) {
                            Circle().fill(.white).stroke(color, lineWidth: 2).frame(width: 9, height: 9)
                                .allowsHitTesting(false)
                        }
                        .annotationTitles(.hidden)
                    }
                }

                // The picked stop's directions, on the side of the street each stops on.
                ForEach(corner) { arrow in
                    Annotation("", coordinate: arrow.position, anchor: .center) {
                        StopArrowMark(rotation: arrow.bearing - heading, isPicked: arrow.id == picked?.id,
                                      offset: arrow.screenOffset(heading: heading),
                                      color: selected?.mapColor ?? LineBadge.red, arrowColor: selected?.badgeTextColor ?? .white)
                    }
                    .annotationTitles(.hidden)
                }
                ForEach(leaving.arrows) { arrow in
                    Annotation("", coordinate: arrow.position, anchor: .center) {
                        StopArrowMark(rotation: arrow.bearing - heading, isPicked: false,
                                      offset: arrow.screenOffset(heading: heading),
                                      color: leaving.line?.mapColor ?? LineBadge.red, arrowColor: leaving.line?.badgeTextColor ?? .white,
                                      isLeaving: true)
                    }
                    .annotationTitles(.hidden)
                }
            }
            // A muted base map lets the route colors carry the picture.
            .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
            .onMapCameraChange(frequency: .continuous) { context in
                heading = context.camera.heading
                // The badges follow a pinch or pan as it happens, not just once it's let go.
                guard Date.now.timeIntervalSince(liveRelabelAt) > 0.15 else { return }
                liveRelabelAt = .now
                measure(context.rect)
                relabel(proxy, showing: context.rect)
            }
            .onMapCameraChange(frequency: .onEnd) {
                visibleRect = $0.rect
                measure($0.rect)
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
            .onChange(of: corner) { old, new in
                // Another stop: its arrows fade in (on their own) while the old ones fade out.
                let gone = old.filter { !new.contains($0) }
                leaving = (gone, cornerLine)
                cornerLine = selected
                guard !gone.isEmpty else { return }
                Task {
                    try? await Task.sleep(for: .seconds(0.4))
                    if leaving.arrows == gone { leaving = ([], nil) }
                }
            }
            .onChange(of: alsoLineIDs) { relabel(proxy) }
            // Alongside the map's own gestures, which would otherwise swallow a plain tap.
            .simultaneousGesture(SpatialTapGesture().onEnded { tap in handleTap(at: tap.location, proxy: proxy) })
        }
        .safeAreaInset(edge: .bottom) {
            // The map fits itself to the space above the card, so a card changing height moves the map.
            // While a line is selected the space only grows: switching lines or stops leaves it be.
            card
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { height in
                    if selectedID == nil || height > cardRoom { cardRoom = height }
                }
                .frame(height: max(cardRoom, 1), alignment: .bottom)
        }
        .overlay {
            if let error {
                ContentUnavailableView("The map didn't show up either", systemImage: "map", description: Text(error))
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
            leavingLabels = [:]
            deselect()
            error = nil
            position = .region(city.region)
            // Instantly from the device (or the app's built-in snapshot), then quietly swap in newer
            // data if the proxy has it; that's checked at most once a day.
            show(TransitService.cachedLineMap(in: city))
            if lines.isEmpty { error = "No line data yet. Your connection is running late too." }
            await blendIn()
            if let newer = await TransitService.refreshedLineMap(in: city), !Task.isCancelled {
                show(newer)
                error = nil
            }
        }
        .task(id: city) {
            allStops = []
            shownStops = []
            // Thousands of them (New York's buses): read off the main thread.
            allStops = await Task.detached(priority: .userInitiated) { TransitService.cachedStops(in: city) }.value
            if let visibleRect { showStops(in: visibleRect) }
            if let newer = await TransitService.refreshedStops(in: city), !Task.isCancelled {
                allStops = newer
                if let visibleRect { showStops(in: visibleRect) }
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
        .task(id: corner.map(\.id)) {
            // Live minutes for each way from the picked stop, side by side. Times already fetched stay
            // (they're by stop and direction), so going back to a stop shows them right away.
            guard let selected else { return }
            let wanted = corner.map { arrow in
                (arrow.id, Selection(lineID: selected.id, lineName: selected.name, directionID: arrow.direction.id,
                                     destination: arrow.direction.destination, stopCode: arrow.stop.code,
                                     stopName: arrow.stop.name, city: city))
            }
            await withTaskGroup(of: (String, [Departure]?).self) { group in
                for (id, selection) in wanted {
                    group.addTask { (id, try? await TransitService.departures(for: selection, client: .map)) }
                }
                for await (id, departures) in group where !Task.isCancelled {
                    if let departures { cornerTimes[id] = departures }
                }
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
                                Button { select(line, among: candidates) } label: {
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
                // Another stop (or line) cross-fades in, rather than the names and rows changing in place.
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            LineBadge(line: selected.id, font: .system(.title3, design: .rounded).weight(.heavy),
                                      color: selected.mapColor, textColor: selected.badgeTextColor)
                            VStack(alignment: .leading, spacing: 2) {
                                if let stop = (picked ?? corner.first)?.stop {
                                    Text(stop.name).font(.headline).lineLimit(1)
                                    Text(picked == nil ? "Which way are you going?" : "Good choice. Probably.")
                                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                } else {
                                    Text(selected.name).font(.headline).lineLimit(1)
                                    Text(arrows.isEmpty ? "Counting the stops…" : "Tap the line where you get on.")
                                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        if !corner.isEmpty {
                            VStack(spacing: 6) {
                                ForEach(corner.sorted(by: isAbove)) { directionRow($0, color: selected.mapColor) }
                            }
                        }
                    }
                    .id(cornerKey)
                    .transition(.opacity)
                }
                .animation(.easeInOut(duration: 0.3), value: cornerKey)
                if let picked {
                    Button { choose(picked) } label: {
                        Text("That's my stop").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LineBadge.red)
                }
            } else {
                Label(lines.isEmpty ? "Asking nicely for the lines…"
                      : shownStops.isEmpty ? "Tap where you wait to zoom in." : "Tap your stop, or your line.",
                      systemImage: "hand.tap")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding()
    }

    /// One way from the picked stop: an arrow pointing the way it goes on the map as it's turned now,
    /// where it ends up, its next stop (which riders know better than the end of the line), and the
    /// minutes until the next ones.
    /// Which stop of which line the card shows, to cross-fade when that changes.
    private var cornerKey: String { "\(selectedID ?? "")|" + corner.map(\.id).sorted().joined(separator: ",") }

    /// Whether `a`'s row goes above `b`'s: the way pointing up the map (as it's turned now) on top,
    /// or for two running across it, the one whose arrow is drawn higher.
    private func isAbove(_ a: StopArrow, _ b: StopArrow) -> Bool {
        let up = { (arrow: StopArrow) in cos((arrow.bearing - heading) * .pi / 180) }
        if abs(up(a) - up(b)) > 0.5 { return up(a) > up(b) }
        return height(of: a) > height(of: b)
    }

    /// How high up the screen `arrow` is drawn, in points from its corner's first stop.
    private func height(of arrow: StopArrow) -> Double {
        guard let origin = corner.first?.position, metersPerPoint.isFinite, metersPerPoint > 0 else { return 0 }
        let north = (arrow.position.latitude - origin.latitude) * 110_540
        let east = (arrow.position.longitude - origin.longitude) * 111_320 * cos(origin.latitude * .pi / 180)
        let h = heading * .pi / 180
        return (north * cos(h) + east * sin(h)) / metersPerPoint - arrow.screenOffset(heading: heading).height
    }

    private func directionRow(_ arrow: StopArrow, color: Color) -> some View {
        let isPicked = arrow.id == picked?.id
        let departures = (cornerTimes[arrow.id] ?? []).filter { $0.time > .now.addingTimeInterval(-30) }
        let stops = arrow.direction.stops
        let next = stops.firstIndex { $0.code == arrow.stop.code }.flatMap { stops.indices.contains($0 + 1) ? stops[$0 + 1].name : nil }
        return Button { withAnimation(.snappy(duration: 0.2)) { picked = arrow } } label: {
            HStack(spacing: 12) {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(isPicked ? color.legible(on: colorScheme) : .secondary)
                    .rotationEffect(.degrees(arrow.bearing - heading))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("To \(arrow.direction.destination)").font(.headline).lineLimit(1)
                    Text(next.map { "Next: \($0)" } ?? "Last stop. Everybody off.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(cornerTimes[arrow.id] == nil ? "…" : Departure.waits(departures, from: .now, count: 2) ?? "none")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(departures.first?.isLive == true ? .green : .secondary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(.primary.opacity(isPicked ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if isPicked {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(color.legible(on: colorScheme), lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("To \(arrow.direction.destination)\(next.map { ", next stop \($0)" } ?? "")")
        .accessibilityAddTraits(isPicked ? .isSelected : [])
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

    /// An arrow at the picked stop picks that direction. Along the selected line, its stop nearest
    /// the tap. Anywhere else, zoomed out too far for stops, it zooms in there; closer, the line
    /// nearest the tap and its stop there (or none: let go).
    private func handleTap(at point: CGPoint, proxy: MapProxy) {
        guard let coordinate = proxy.convert(point, from: .local),
              let edge = proxy.convert(CGPoint(x: point.x + 24, y: point.y), from: .local)
        else { return }
        let hit = corner
            .compactMap { arrow -> (StopArrow, CGFloat)? in
                // Measure to where the arrow is drawn, not to the stop it belongs to.
                guard let stop = proxy.convert(arrow.position, to: .local) else { return nil }
                let shift = arrow.screenOffset(heading: heading)
                let distance = hypot(stop.x + shift.width - point.x, stop.y + shift.height - point.y)
                return distance <= 22 ? (arrow, distance) : nil
            }
            .min { $0.1 < $1.1 }?.0
        if let hit {
            withAnimation(.snappy(duration: 0.2)) { picked = hit }
            return
        }
        // A stop dot: the lines around it as chips, the selected one kept if it stops there (and
        // moved to that stop at once, while the others are looked up).
        if let stop = shownStops
            .compactMap({ stop -> (MapStop, CGFloat)? in
                guard let spot = proxy.convert(stop.coordinate, to: .local) else { return nil }
                let distance = hypot(spot.x - point.x, spot.y - point.y)
                return distance <= 16 ? (stop, distance) : nil
            })
            .min(by: { $0.1 < $1.1 })?.0 {
            tapCoordinate = stop.coordinate
            if arrows.contains(where: { $0.stop.code == stop.code }) {
                withAnimation(.snappy(duration: 0.25)) { pickCorner(near: stop.coordinate) }
            }
            selectStop(stop, proxy: proxy)
            return
        }
        tapCoordinate = coordinate
        if let selectedID, !arrows.isEmpty,
           (paths[selectedID] ?? []).map({ distanceToPath(coordinate, $0) }).min() ?? .infinity <= meters(coordinate, edge) {
            withAnimation(.snappy(duration: 0.25)) { pickCorner(near: coordinate) }
            return
        }
        guard !shownStops.isEmpty else {
            zoomIn(on: coordinate)
            return
        }
        selectLine(near: point, proxy: proxy)
    }

    /// Zooms in on `coordinate`, just far enough for the stops around it to show (or, with none
    /// around, a step closer).
    private func zoomIn(on coordinate: CLLocationCoordinate2D) {
        guard let visibleRect, mapSize.width > 0 else { return }
        let center = MKMapPoint(coordinate)
        let metersPerMapPoint = MKMetersPerMapPointAtLatitude(coordinate.latitude)
        func around(_ size: MKMapSize) -> MKMapRect {
            MKMapRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        }
        func fewEnoughStops(_ rect: MKMapRect) -> Bool {
            rect.width * metersPerMapPoint / mapSize.width < Self.stopsConsideredBelowMetersPerPoint
                && allStops.lazy.filter { rect.contains(MKMapPoint($0.coordinate)) }.count <= Self.mostStopsInView
        }
        var size = visibleRect.size
        repeat {
            size = MKMapSize(width: size.width * 0.8, height: size.height * 0.8)
        } while !fewEnoughStops(around(size)) && size.width * metersPerMapPoint > 600
        withAnimation(.smooth(duration: 0.8)) { position = .rect(around(size)) }
    }

    /// Picks the selected line's stop nearest `coordinate`, with its directions; a stop served one way
    /// only (a terminal, a loop) has its one direction picked already.
    private func pickCorner(near coordinate: CLLocationCoordinate2D) {
        corner = StopArrow.corner(near: coordinate, in: arrows)
        picked = corner.count == 1 ? corner.first : nil
        // From the whole city, zoom in to the stop, so its arrows and the stops around it can be
        // told apart (and another one tapped instead).
        if let stop = corner.first?.position, metersPerPoint > Self.dotsBelowMetersPerPoint {
            withAnimation(.smooth(duration: 0.6)) {
                position = .region(MKCoordinateRegion(center: stop, latitudinalMeters: 900, longitudinalMeters: 900))
            }
        }
    }

    /// Notes how zoomed in the map is, for the stop dots.
    private func measure(_ rect: MKMapRect) {
        guard mapSize.width > 0 else { return }
        metersPerPoint = rect.width * MKMetersPerMapPointAtLatitude(rect.origin.coordinate.latitude) / mapSize.width
        showStops(in: rect)
    }

    /// The stops in (and just around) `rect`, once few enough are in view to tell apart: sooner where
    /// stops are sparse (out in the suburbs, along a ferry route) than downtown. None with more in view,
    /// where they'd bury the lines (and slow the map down).
    private func showStops(in rect: MKMapRect) {
        let inView = metersPerPoint < Self.stopsConsideredBelowMetersPerPoint
            ? allStops.filter { rect.contains(MKMapPoint($0.coordinate)) } : []
        guard !inView.isEmpty, inView.count <= Self.mostStopsInView else {
            if !shownStops.isEmpty { shownStops = [] }
            return
        }
        let area = rect.insetBy(dx: -rect.width * 0.15, dy: -rect.height * 0.15)
        let nearby = allStops.filter { area.contains(MKMapPoint($0.coordinate)) }
        if nearby.map(\.code) != shownStops.map(\.code) { shownStops = nearby }
    }

    /// Stops show once no more than this many are in view.
    private static let mostStopsInView = 120
    /// Further out than this (a few miles across), they aren't even counted.
    private static let stopsConsideredBelowMetersPerPoint = 30.0

    /// Selects a line that stops at `stop`, with every line at the stops around it as chips (a busy
    /// corner like Market and Church has a stop per line and direction), and opens on that stop.
    /// Which lines stop where comes with the stops, or else from the proxy (Muni's, from the live
    /// times); if none are running, the lines passing by will do.
    private func selectStop(_ stop: MapStop, proxy: MapProxy) {
        lineLoad?.cancel()
        lineLoad = Task {
            // Nearest first, so the tapped stop's own lines lead.
            let around = allStops
                .map { ($0, meters($0.coordinate, stop.coordinate)) }
                .filter { $0.1 <= Self.cornerMeters }
                .sorted { $0.1 < $1.1 }
                .map(\.0)
            var linesAt = Dictionary(around.compactMap { s in s.lines.map { (s.code, $0) } }, uniquingKeysWith: { a, _ in a })
            let asking = around.filter { $0.lines == nil }.map(\.code)
            if !asking.isEmpty, let found = try? await TransitService.linesAtStops(asking, in: city) {
                for line in found { linesAt[line.stop ?? asking[0], default: []].append(line.line) }
            }
            guard !Task.isCancelled else { return }
            let here = around.flatMap { linesAt[$0.code] ?? [] }.reduce(into: [MapLine]()) { found, id in
                if let line = lines.first(where: { $0.id == id }), !found.contains(where: { $0.id == id }) { found.append(line) }
            }
            if let first = here.first(where: { $0.id == selectedID }) ?? here.first {
                select(first, among: here)
            } else if let point = proxy.convert(stop.coordinate, to: .local) {
                selectLine(near: point, proxy: proxy)
            }
        }
    }

    /// How far around a tapped stop its corner reaches: as far as "Also fine with" looks (the proxy's
    /// NEARBY_METERS), a minute or two on foot.
    private static let cornerMeters = 150.0

    /// Stops along a line are a few hundred meters apart; this far in, that's a fingertip or more.
    private static let dotsBelowMetersPerPoint = 6.0

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
        guard let nearest = nearby.first else { return withAnimation(.snappy(duration: 0.25)) { deselect() } }
        select(nearest, among: Array(nearby))
    }

    /// Selects `line` and its stop nearest the last tap together, once its stops are at hand, so the
    /// card and map change once, straight from the old line to the new one. Stops seen before are on
    /// the device already; others need one download, during which the old line stays up.
    private func select(_ line: MapLine, among nearby: [MapLine]) {
        lineLoad?.cancel()
        let show = { (loaded: [Direction]) in
            let lineArrows = StopArrow.arrows(for: loaded, lineShape: paths[line.id] ?? [])
            withAnimation(.snappy(duration: 0.25)) {
                candidates = nearby
                selectedID = line.id
                directions = loaded
                arrows = lineArrows
                stopDots = StopArrow.corners(of: lineArrows)
                corner = []
                picked = nil
                if let tapCoordinate { pickCorner(near: tapCoordinate) }
            }
        }
        if let cached = TransitService.cachedDirections(for: line.line, in: city) { return show(cached) }
        lineLoad = Task {
            guard let loaded = try? await TransitService.directions(for: line.line, in: city), !Task.isCancelled else { return }
            show(loaded)
        }
    }

    /// Brings the lines up from nothing in a few steps (map lines don't animate on their own), after
    /// the map has had a moment to zoom in and draw its streets.
    private func blendIn() async {
        fade = 0
        try? await Task.sleep(for: .seconds(0.35))
        for step in 1...6 {
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.06)) { fade = Double(step) / 6 }
            try? await Task.sleep(for: .seconds(0.06))
        }
    }

    /// Places the line badges for what the map shows now.
    private func relabel(_ proxy: MapProxy, showing rect: MKMapRect? = nil) {
        guard let visibleRect = rect ?? visibleRect, mapSize.width > 0, !labelSpots.isEmpty else { return }
        let metersPerPoint = visibleRect.width * MKMetersPerMapPointAtLatitude(visibleRect.origin.coordinate.latitude) / mapSize.width
        // Clear of the edges, so no badge is cut off.
        let bounds = CGRect(origin: .zero, size: mapSize).insetBy(dx: 8, dy: 6)
        let placed = LineLabels.place(
            lines: lines, spots: labelSpots, excluding: alsoLineIDs.union([selectedID].compactMap { $0 }),
            previous: labels, visible: visibleRect, bounds: bounds, metersPerPoint: metersPerPoint,
            convert: { proxy.convert($0, to: .local) })
        // Map annotations can't animate coming and going, so a badge taken off stays a moment to fade out.
        let now = Date.now
        let placedIDs = Set(placed.map(\.id))
        for label in labels where !placedIDs.contains(label.id) {
            leavingLabels[label.id] = (label, now + LineLabel.fadeDuration)
        }
        leavingLabels = leavingLabels.filter { !placedIDs.contains($0.key) && $0.value.until > now }
        labels = placed
        Task {
            try? await Task.sleep(for: .seconds(LineLabel.fadeDuration + 0.05))
            leavingLabels = leavingLabels.filter { $0.value.until > .now }
        }
    }

    private func show(_ loaded: [MapLine]) {
        guard !loaded.isEmpty else { return }
        paths = Dictionary(uniqueKeysWithValues: loaded.map { line in
            (line.id, line.shapes.map { $0.compactMap { $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil } })
        })
        pathsVersion += 1
        lines = loaded
        // A refresh may have dropped the selected line (a service change); let go of it then.
        if let selectedID, !loaded.contains(where: { $0.id == selectedID }) { deselect() }
    }

    private func deselect() {
        lineLoad?.cancel()
        candidates = []
        selectedID = nil
        directions = []
        arrows = []
        stopDots = []
        corner = []
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
    static let sideOffset: CGFloat = 17

    /// Where to draw the arrow relative to its stop, on a map rotated by `heading`.
    func screenOffset(heading: Double) -> CGSize {
        let right = (bearing + 90 - heading) * .pi / 180
        return CGSize(width: Self.sideOffset * sin(right), height: -Self.sideOffset * cos(right))
    }

    static func == (a: StopArrow, b: StopArrow) -> Bool { a.id == b.id }

    /// A stop as riders think of it: the stop nearest `point`, plus for each other direction its stop
    /// closest to that one, if it's within a short walk (the other way may run a street over, or not
    /// pass by at all). Ordered by direction, so the rows don't swap places from stop to stop.
    static func corner(near point: CLLocationCoordinate2D, in arrows: [StopArrow]) -> [StopArrow] {
        guard let nearest = arrows.min(by: { meters($0.position, point) < meters($1.position, point) }) else { return [] }
        return Dictionary(grouping: arrows, by: \.direction.id).values
            .compactMap { way in way.min { meters($0.position, nearest.position) < meters($1.position, nearest.position) } }
            .filter { $0.id == nearest.id || meters($0.position, nearest.position) < 200 }
            .sorted { $0.direction.id < $1.direction.id }
    }

    /// One spot per corner: stops of either direction within 40 m of one already kept are left out.
    static func corners(of arrows: [StopArrow]) -> [StopDot] {
        var kept: [StopDot] = []
        for arrow in arrows where !kept.contains(where: { meters($0.coordinate, arrow.position) < 40 }) {
            kept.append(StopDot(latitude: arrow.position.latitude, longitude: arrow.position.longitude))
        }
        return kept
    }

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

/// White arrow with a dark rim, readable on any map, for a direction at the picked stop; the picked
/// direction grows and takes the line's color.
private struct StopArrowMark: View {
    let rotation: Double
    let isPicked: Bool
    let offset: CGSize
    let color: Color
    /// The arrow on the line's color, as on its badge (black on BART's yellow).
    let arrowColor: Color
    /// One of the stop just let go of: it fades out instead of in.
    var isLeaving = false

    @State private var shown = false

    var body: some View {
        // In a circle, so it stands out from the lines and streets: the line's color with a white
        // rim, and once picked, white and bigger.
        ZStack {
            Circle()
                .fill(isPicked ? .white : color)
                .stroke(.white, lineWidth: isPicked ? 0 : 2)
                .frame(width: isPicked ? 36 : 28, height: isPicked ? 36 : 28)
                .shadow(color: .black.opacity(0.5), radius: 3)
            Image(systemName: "location.north.fill")
                .font(.system(size: isPicked ? 18 : 14, weight: .bold))
                .foregroundStyle(isPicked ? color : arrowColor)
                .rotationEffect(.degrees(rotation))
        }
        .scaleEffect(shown != isLeaving ? 1 : 0.6)
        .opacity(shown != isLeaving ? 1 : 0)
        .onAppear { withAnimation(.easeInOut(duration: 0.3)) { shown = true } }
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
        case .nyc:
            MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 40.72, longitude: -73.94),
                               span: MKCoordinateSpan(latitudeDelta: 0.28, longitudeDelta: 0.28))
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
/// Every line on the map. Kept apart and equatable so the labels updating while you pinch don't make
/// SwiftUI rebuild hundreds of lines (New York has over 500) each time.
private struct LineLayer: MapContent, Equatable {
    let lines: [MapLine]
    let paths: [String: [[CLLocationCoordinate2D]]]
    let pathsVersion: Int
    let selectedID: String?
    let alsoLineIDs: Set<String>
    let candidateIDs: Set<String>
    let colorScheme: ColorScheme
    let isBackground: (MapLine) -> Bool
    /// 0 to 1 as the lines blend in.
    let fade: Double

    static func == (a: Self, b: Self) -> Bool {
        a.fade == b.fade && a.pathsVersion == b.pathsVersion && a.selectedID == b.selectedID && a.alsoLineIDs == b.alsoLineIDs
            && a.candidateIDs == b.candidateIDs && a.colorScheme == b.colorScheme && a.lines.map(\.id) == b.lines.map(\.id)
    }

    var body: some MapContent {
        ForEach(lines) { line in
            let isSelected = line.id == selectedID || alsoLineIDs.contains(line.id)
            let isCandidate = !isSelected && candidateIDs.contains(line.id)
            // Many lines share a color (all Muni buses are blue), so only the selected line
            // keeps full strength; nearby ones stay a bit clearer than the rest.
            // New York's buses are a fine, faint web under the trains until one is picked.
            let background = isBackground(line) && !isSelected
            let width: CGFloat = isSelected ? 7 : isCandidate ? 3.5 : background ? 1.5 : 3
            let ferry = line.mode == "ferry"
            ForEach(Array((paths[line.id] ?? []).enumerated()), id: \.offset) { _, path in
                MapPolyline(coordinates: path)
                    .stroke(line.mapColor.legible(on: colorScheme)
                                .opacity((selectedID == nil || isSelected ? 1 : isCandidate ? 0.5 : 0.22) * (background && !isCandidate ? 0.45 : 1) * fade),
                            // Ferries dashed across the water (flat ends, or round ones would fill the gaps).
                            style: StrokeStyle(lineWidth: width, lineCap: ferry ? .butt : .round, lineJoin: .round,
                                               dash: ferry ? [width * 2.5, width * 1.5] : []))
            }
        }
    }
}

/// A line badge that fades in when it appears and fades out once `leaving`.
private struct FadingBadge<Content: View>: View {
    let leaving: Bool
    @ViewBuilder let content: Content
    @State private var appeared = false

    var body: some View {
        content
            .opacity(appeared && !leaving ? 1 : 0)
            .animation(.easeInOut(duration: LineLabel.fadeDuration), value: appeared && !leaving)
            .onAppear { appeared = true }
    }
}

struct LineLabel: Identifiable, Equatable {
    let lineID: String
    let spot: Int
    let coordinate: CLLocationCoordinate2D

    var id: String { "\(lineID)|\(spot)" }

    /// How long a badge takes to fade in or out.
    static let fadeDuration: TimeInterval = 0.3

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
        if id.hasSuffix("-SBS") { return 0 }                                      // New York's Select Bus Service
        // New York's express buses, mostly into Manhattan from far out.
        if ["BM", "QM", "SIM", "X"].contains(where: { id.hasPrefix($0) && id.dropFirst($0.count).first?.isNumber == true }) {
            return 2
        }
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

    /// The badges to show in `bounds` (screen points) at `metersPerPoint`. The badges in `previous` stay
    /// where they are if they still fit, so nothing hops around while zooming; then the lines are placed
    /// in tier order, each at its roomiest free spot, those with the fewest spots on screen first so they
    /// aren't crowded out.
    static func place(lines: [MapLine], spots: [String: [LabelSpot]], excluding: Set<String>,
                      previous: [LineLabel], visible: MKMapRect, bounds: CGRect, metersPerPoint: Double,
                      convert: (CLLocationCoordinate2D) -> CGPoint?) -> [LineLabel] {
        let maxTier = metersPerPoint < 4.5 ? 2 : metersPerPoint < 22 ? 1 : 0
        let perLine = metersPerPoint < 9 ? 3 : 1
        let candidates = lines.compactMap { line -> (line: MapLine, tier: Int, spots: [(index: Int, spot: LabelSpot, at: CGPoint, score: Double)])? in
            let tier = tier(of: line)
            guard tier <= maxTier, !excluding.contains(line.id) else { return nil }
            let onScreen = (spots[line.id] ?? []).enumerated().compactMap { index, spot -> (Int, LabelSpot, CGPoint, Double)? in
                guard visible.contains(spot.point), let at = convert(spot.coordinate), bounds.contains(at) else { return nil }
                // Room in screen points, capped: past a badge's height, more room doesn't matter.
                return (index, spot, at, min(spot.room / metersPerPoint, 30))
            }
            // Ties (common up close, where many spots hit the cap) go in a fixed order.
            return onScreen.isEmpty ? nil : (line, tier, onScreen.sorted { ($0.3, -$0.0) > ($1.3, -$1.0) })
        }
        .sorted { ($0.tier, $0.spots.count, $0.line.id) < ($1.tier, $1.spots.count, $1.line.id) }

        // The Apple Maps logo and Legal link sit in the bottom-left corner.
        var taken = [CGRect(x: bounds.minX - 8, y: bounds.maxY - 34, width: 150, height: 40)]
        var labels: [LineLabel] = []
        var placedAt: [String: [CGPoint]] = [:]

        /// Puts a badge for `line` at `at` if it's in bounds, clear of the others and far enough from
        /// the line's other badges. One already showing may run past the edge, so it slides off with the map.
        func add(_ line: String, spot: Int, coordinate: CLLocationCoordinate2D, at: CGPoint, showing: Bool = false) {
            let mine = placedAt[line, default: []]
            guard mine.count < perLine, !mine.contains(where: { hypot($0.x - at.x, $0.y - at.y) < 260 }) else { return }
            let size = CGSize(width: 14 + 7.5 * Double(line.count), height: 20)
            let box = CGRect(x: at.x - size.width / 2, y: at.y - size.height / 2,
                             width: size.width, height: size.height).insetBy(dx: -4, dy: -3)
            guard showing || bounds.contains(box), !taken.contains(where: { $0.intersects(box) }) else { return }
            taken.append(box)
            placedAt[line, default: []].append(at)
            labels.append(LineLabel(lineID: line, spot: spot, coordinate: coordinate))
        }

        // First the badges already showing, in the order they were placed.
        let byLine = Dictionary(uniqueKeysWithValues: candidates.map { ($0.line.id, $0.spots) })
        for old in previous {
            guard let spot = byLine[old.lineID]?.first(where: { $0.index == old.spot }) else { continue }
            add(old.lineID, spot: spot.index, coordinate: spot.spot.coordinate, at: spot.at, showing: true)
        }
        // Then the room that's left.
        for (line, _, spots) in candidates {
            if labels.count >= 60 { break }
            for spot in spots where placedAt[line.id, default: []].count < perLine {
                add(line.id, spot: spot.index, coordinate: spot.spot.coordinate, at: spot.at)
            }
        }
        return labels
    }
}

extension MapStop {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

/// A stop dot on the map, identified by where it is.
struct StopDot: Hashable {
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

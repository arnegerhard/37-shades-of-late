import MapKit
import SwiftUI

/// The home map, of a city: one map for the open stop and for finding another, with three layers on
/// it, each switched on and off on its own (see `MapLayers`): the open stop's route and the buses
/// coming to it (see `LiveRoute`); the city's lines, as many as can be told apart at the zoom, the
/// lesser ones blending in further in (see `cull`); and, opened out over the whole page (`picking`),
/// the stop picker's own, as far in and where it was. With a stop open, only its route; before there
/// is one, the city's lines; picking, all three.
///
/// Picking: zoomed out, where a fingertip covers several lines, a tap zooms in on where it landed,
/// just far enough for the stops there to show. Tap a line where you catch it: that selects the line
/// (lines running close together are offered as chips) and its stop nearest the tap. The card then
/// offers the ways it goes from there, each with an arrow that points like the map, where it heads,
/// its next stop and its live minutes; the same arrows sit at the stop on the map. Tap along the
/// line for another stop, anywhere else to let go of it. Zoomed in to a neighborhood, every stop shows
/// as a white dot; tapping one selects a line that stops there (the others as chips) and that stop.
struct HomeMap: View {
    let city: City
    /// The stop open on the map, whose route and buses it shows; none, the city's main lines.
    var open: Selection? = nil
    /// Shared with the departure list, so both always show the same buses and times.
    var feed: DepartureFeed? = nil
    /// Opened out over the whole page (full screen, or for the picker), at its height and taking touches.
    var expanded = false
    /// Turned into the stop picker, and opened out to show it: the city's lines are on it while it's
    /// open, and blend out as it closes, before it stops being the picker.
    var picking = false
    var opened = false
    /// Points at the top covered by something drawn over the map, kept clear of the route.
    var topInset: CGFloat = 0
    /// Points at the bottom covered by what's drawn over the map (a caption, the home indicator), kept
    /// clear of the route and, picking, of the card.
    var bottomInset: CGFloat = 0
    /// Points at the left covered by what's drawn over the map, kept clear of the route.
    var leadingInset: CGFloat = 0
    /// Points at the bottom of the map out of sight, below what holds it, while it isn't expanded: the
    /// map is always as tall as when it is, and only shown as far as the home screen has room for.
    var hiddenBottom: CGFloat = 0
    /// Points at the top cut off by whatever holds the map (the home screen's, shrunk over a scrolled
    /// list), also kept clear of the route. Only changed once the list is at rest.
    var cropped: CGFloat = 0
    /// Two fingers moving the map, as they go, while it takes no touches itself.
    var gesture: MapGesture? = nil
    /// A tap on the map, while it takes no touches itself (see `MapTouches`).
    var tap: MapTap? = nil
    /// How far a finger has pulled the full screen map down by its top to close it: the card fades.
    var pulled: CGFloat = 0
    let onPick: (Selection) -> Void

    @State private var lines: [MapLine] = []
    @State private var paths: [String: [[CLLocationCoordinate2D]]] = [:]
    /// Bumped whenever `paths` changes, so the lines' layer can tell it's unchanged cheaply.
    @State private var pathsVersion = 0
    @State private var polylines: [String: [MKPolyline]] = [:]
    /// Ferries in longer dashes, further out (see `Prepared.farPolylines`).
    @State private var farPolylines: [String: [MKPolyline]] = [:]
    /// Where the ferries' dashes are drawn: only in and around the view, unless the whole city shows (see
    /// `cull`), and whether in the longer ones.
    @State private var ferryArea: MKMapRect?
    @State private var farFerries = true
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
    /// Where the map's camera is, to slide it without zooming.
    @State private var camera: MapCamera?
    /// Where each line's name badge may go (worked out once per line map), and the badges shown now.
    @State private var labelSpots: [String: [LabelSpot]] = [:]
    @State private var labels: [LineLabel] = []

    /// The badges to draw, those going too, each with its line's look.
    private var shownBadges: [LineBadgesLayer.Badge] {
        (labels + leavingLabels.values.map(\.label).sorted { $0.id < $1.id }).compactMap { label in
            guard let line = lines.first(where: { $0.id == label.lineID }) else { return nil }
            return LineBadgesLayer.Badge(id: label.id, coordinate: label.coordinate, leaving: leavingLabels[label.id] != nil,
                                         text: LineBadge.short(line.id, in: city), color: line.mapColor.legible(on: colorScheme),
                                         textColor: line.badgeTextColor, round: LineBadge.isRound([line.id], in: city), spoken: line.id)
        }
    }
    /// Badges just taken off, kept on the map while they fade out, until the given time.
    @State private var leavingLabels: [String: (label: LineLabel, until: Date)] = [:]
    /// When the badges were last placed during a camera move, to do it only a few times a second.
    @State private var liveRelabelAt: Date = .distantPast
    /// The map's frame, which stops at the header above and the card below.
    @State private var mapSize: CGSize = .zero
    /// How much of the map's bottom the picker's card covers, its padding included.
    @State private var cardRoom: CGFloat = 0
    /// Whether the card (or the circle's list) is tucked away into a bar at the bottom, for more map;
    /// and how far a finger is dragging it.
    @State private var tucked = false
    @State private var cardDrag: CGFloat = 0
    /// How zoomed in the map is; stop dots show once stops are a fingertip apart.
    @State private var metersPerPoint: Double = .infinity
    /// Every stop in the city; those around once few enough are in view to tell apart, for the circle;
    /// and the dots on the map, stops too close together to tell apart as one (see `showStops`).
    @State private var allStops: [MapStop] = []
    @State private var stopsAround: [MapStop] = []
    @State private var shownStops: [MapStop] = []
    /// The area the dots were last chosen for, and their squares' size (see `showStops`).
    @State private var dotsArea: MKMapRect?
    @State private var dotsSquare = 0.0
    /// Zoomed in to the stops, a circle in the middle of the map gathers those within a short walk
    /// (`cornerMeters`) of it: their codes, nearest the middle first, and once looked up, the lines
    /// and directions at each. Its size on screen, in points across.
    @State private var circleCodes: [String] = []
    @State private var circleStops: [CircleStop] = []
    /// The lines in the circle as the map last came to rest (see `circleLineIDs`), and whether it's moving.
    @State private var drawnCircleLineIDs: Set<String> = []
    @State private var moving = false
    /// Lines' directions read for the circle so far, by line: reading them again (Seattle's come with
    /// their whole route shapes) every time it moves would keep the phone busy for seconds.
    @State private var circleDirections: [String: [Direction]] = [:]
    /// How tall the circle's list is at most, and its rows now. It doesn't push the map up (that
    /// would zoom it out, away from the stops that brought the list up): it lies over the map instead.
    /// The circle sits in the middle of what the tallest list leaves, wherever the list ends now, or
    /// the list's height would move the circle, which changes the list.
    private static let circleListHeight: CGFloat = 240
    @State private var circleRowsHeight: CGFloat = 0
    /// Where the card (or the circle's list) and the map are on screen, to tell taps on the card from
    /// taps on the map, and when the map was last tapped.
    @State private var cardFrame: CGRect = .null
    @State private var tappedAt = Date.distantPast
    @State private var mapFrame: CGRect = .zero
    @State private var error: String?
    @State private var position: MapCameraPosition
    @Environment(\.colorScheme) private var colorScheme

    /// The open stop's route, stop and buses.
    @State private var live = LiveRoute()
    /// What changes as the map moves (see `MapMotion`).
    @State private var motion = MapMotion()
    /// The height of map showing that the route was last framed for.
    @State private var fittedRoom: CGFloat = 0
    /// Each line's extent and tier (see `LineLabels.tier`), for `cull`.
    @State private var lineBounds: [String: MKMapRect] = [:]
    @State private var lineTiers: [String: Int] = [:]
    /// The lines in view that the zoom can tell apart.
    @State private var culledIDs: Set<String> = []
    /// What the lines in `culledIDs` were chosen for: the area around the map's view, the zoom's tier,
    /// and how many lines the city has (more, once newer ones load).
    @State private var culledFor: (area: MKMapRect?, tier: Int, lines: Int) = (nil, -1, 0)
    /// The layers on the map now, on their way to `wantedLayers` (see `switchLayers`).
    @State private var layers: MapLayers
    /// The city's lines waiting to come in over the route until the picker has opened out.
    @State private var switching: Task<Void, Never>?
    @State private var fader = MapFader()
    /// How tall the map is now (see `keepClear`), and its camera as it moves.
    @State private var mapHeight: CGFloat = 0
    /// The height the map has room for, all of it: as tall as the page.
    @State private var fullHeight: CGFloat = 0
    /// Whether the map was last made as tall as the expanded one, and the correction under way (see `keepClear`).
    @State private var sizedExpanded = false
    @State private var keeping: Task<Void, Never>?
    /// A stop picked in the picker, its route to frame once the map is back to its size.
    @State private var routeToFrame = false
    /// When it opened: the second tap of the double tap that opened it isn't one of its own.
    @State private var openedAt = Date.now

    init(city: City, open: Selection? = nil, feed: DepartureFeed? = nil, expanded: Bool = false, picking: Bool = false, opened: Bool = false, topInset: CGFloat = 0,
         bottomInset: CGFloat = 0, leadingInset: CGFloat = 0, hiddenBottom: CGFloat = 0, cropped: CGFloat = 0, gesture: MapGesture? = nil, tap: MapTap? = nil, pulled: CGFloat = 0,
         onPick: @escaping (Selection) -> Void = { _ in }) {
        self.city = city
        self.open = open
        self.feed = feed
        self.expanded = expanded
        self.picking = picking
        self.opened = opened
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.leadingInset = leadingInset
        self.hiddenBottom = hiddenBottom
        self.cropped = cropped
        self.gesture = gesture
        self.tap = tap
        self.pulled = pulled
        self.onPick = onPick
        _position = State(initialValue: .region(city.region))
        _layers = State(initialValue: MapLayers(open: open, opened: opened))
    }

    /// The departures the feed has for the open stop.
    private var departures: [Departure] { feed?.loaded?.id == open?.id ? feed?.departures ?? [] : [] }

    /// How tall the map should be: down to what's out of sight below the home screen's room for it, or
    /// to the picker's card.
    private var wantedHeight: CGFloat { max(fullHeight - (expanded ? 0 : hiddenBottom), 0) }
    /// How tall it is, all of it in sight but the top `cropped` points.
    private var shownHeight: CGFloat { max(mapSize.height, 1) }
    /// Where what lies over the map's bottom begins, picking: the card, or the circle's tallest list
    /// (see `circleListHeight`) with its padding (16 inside, 16 around, and `logoRoom` below) and the
    /// close button above it.
    private var clearBottom: CGFloat {
        guard picking else { return shownHeight }
        return max(cropped + 1, shownHeight - (isCircling && !tucked ? Self.circleListHeight + 64 + Self.closeRoom + Self.logoRoom + bottomInset : cardRoom))
    }
    /// The room left under the card and the circle's list, lying over the map, for the Apple Maps logo
    /// and Legal link at its bottom.
    private static let logoRoom: CGFloat = 26
    /// The close button's room above the card.
    private static let closeRoom: CGFloat = 38

    /// What lies over the map's top and left, for `frameRoute`.
    private var overlaid: CGSize { CGSize(width: leadingInset, height: topInset) }

    /// The layers the map is to show, as it is: the open stop's, the picker's.
    private var wantedLayers: MapLayers { MapLayers(open: open, opened: opened) }

    /// The lines drawn: those `cull` leaves, and any the picker has brought up.
    private var visibleLineIDs: Set<String> {
        guard layers.lines else { return [] }
        return culledIDs.union(alsoLineIDs).union(candidates.map(\.id)).union(drawnCircleLineIDs).union([selectedID].compactMap { $0 })
    }

    private var selected: MapLine? { candidates.first { $0.id == selectedID } }

    /// Whether the circle is out: zoomed in to the stops, with no line picked yet.
    private var isCircling: Bool { selectedID == nil && !stopsAround.isEmpty }

    /// The lines stopping inside the circle, drawn up on the map while it's out.
    private var circleLineIDs: Set<String> {
        isCircling ? Set(circleStops.flatMap { $0.ways.map(\.line.id) }) : []
    }

    /// The lines added with "Also fine with" (their map line IDs).
    private var alsoLineIDs: Set<String> {
        Set(otherLines.filter { alsoIDs.contains($0.id) }.map(\.line))
    }

    /// The other stops the added lines are caught at, to walk to.
    private var walkStops: [StopLine] {
        otherLines.filter { alsoIDs.contains($0.id) && $0.isNearby && $0.lat != nil && $0.lon != nil }
    }

    /// New York's, Boston's, Chicago's, Washington's and Los Angeles's buses, which outnumber their
    /// trains more than ten to one (Boston's Silver Line and LA's G and J busways aside, which run like them).
    private func isBackground(_ line: MapLine) -> Bool {
        guard [.nyc, .boston, .chicago, .dc, .la].contains(city), line.mode == "bus" else { return false }
        return city == .boston ? !line.id.hasPrefix("SL") : city == .la ? !["G", "J"].contains(line.id) : true
    }

    private var drawOrder: [MapLine] {
        let also = alsoLineIDs
        // In New York, Boston, Chicago and Washington the buses go underneath, so the trains stay readable on top of them.
        let visible = visibleLineIDs
        guard !visible.isEmpty else { return [] }
        let rest = lines.filter { visible.contains($0.id) && $0.id != selectedID && !also.contains($0.id) }
        return rest.filter(isBackground) + rest.filter { !isBackground($0) }
            + lines.filter { also.contains($0.id) }
            + lines.filter { $0.id == selectedID }
    }

    /// The city's lines and their names, selected line last, so it's drawn on top of the lines it shares
    /// streets with. Off, none (`visibleLineIDs`, `relabel`).
    @MapContentBuilder private var linesLayer: some MapContent {
        LineLayer(lines: drawOrder, polylines: polylines, farPolylines: farPolylines, ferryArea: ferryArea, farFerries: farFerries,
                  pathsVersion: pathsVersion, selectedID: selectedID,
                  alsoLineIDs: alsoLineIDs, candidateIDs: Set(candidates.map(\.id)), circleLineIDs: drawnCircleLineIDs,
                  colorScheme: colorScheme, isBackground: isBackground)

        // The line names aren't on the map, but over it: see `LineBadgesLayer`.
    }

    /// The open stop's route and stop, as they are, picking or not: the city's lines come and go under
    /// them. Stepping back while the picker has a line picked. (Its buses go over the map: `BusLayer`.)
    @MapContentBuilder private var routeLayer: some MapContent {
        if layers.route {
            RouteLayer(live: live, city: city, motion: motion, dimmed: selectedID != nil, colorScheme: colorScheme)
        }
    }

    /// The picker's own: the stops around once zoomed in, the selected line's stops, the picked stop's
    /// directions, and the lines added with "Also fine with".
    @MapContentBuilder private var pickingLayer: some MapContent {
        if layers.picking {
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

            // The stop dots aren't on the map, but over it: see `StopDotsLayer`.

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
    }

    var body: some View {
        MapReader { proxy in
            // Unless expanded, it takes no drags itself: one finger's go to the pages it's on, and two
            // fingers' come in as `gesture`. Taps still reach it, for the picker.
            Map(position: $position, bounds: city.cameraBounds, interactionModes: expanded ? [.pan, .zoom, .rotate] : []) {
                // Bottom up: the city's lines, the open stop's route over them, the picker's own on top.
                linesLayer
                routeLayer
                pickingLayer
            }
            // As tall as it shows: above what's cut off below it on the home screen, or above the picker's
            // card, so the Apple Maps logo and Legal link are in sight. (Not a safe area: with one, MapKit
            // applies a camera other than it reports, and SwiftUI applies the camera again whenever what's
            // on the map changes.) A change of height keeps the map where it is (see `keepClear`).
            .frame(height: mapHeight)
            .onAppear { mapHeight = wantedHeight }
            .onChange(of: wantedHeight) { keepClear(proxy) }
            // A muted base map lets the route colors carry the picture.
            .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
            // Under the buses: the map's picture, blending what changes (see `MapFader`).
            .overlay { MapFader.Host(fader: fader).allowsHitTesting(false) }
            .overlay {
                if layers.lines {
                    LineBadgesLayer(badges: shownBadges, stepBack: selectedID != nil, proxy: proxy, motion: motion, mapSize: mapSize)
                }
            }
            .overlay {
                if layers.picking {
                    StopDotsLayer(stops: shownStops, inside: isCircling ? Set(circleCodes) : [],
                                  lineDots: stopDots.map(\.coordinate), lineDotsBelow: Self.dotsBelowMetersPerPoint,
                                  lineColor: (selected?.mapColor ?? LineBadge.red).legible(on: colorScheme), proxy: proxy, motion: motion, mapSize: mapSize)
                }
            }
            .overlay {
                if layers.route {
                    BusLayer(live: live, departures: departures, proxy: proxy, motion: motion, mapSize: mapSize)
                }
            }
            .modifier(FollowsGesture(gesture: gesture, city: city, proxy: proxy, position: $position))
            .overlay {
                // Not a map circle: drawn over the map's middle, it stays put while the map moves under it.
                if layers.picking, isCircling {
                    PickerCircle(motion: motion)
                        .position(circleSpot)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: isCircling)
            .onMapCameraChange(frequency: .continuous) { context in
                if !moving { moving = true }
                motion.shown = context.rect
                // Moved under the map's picture: it goes at once.
                fader.moved(to: context.rect)
                // The route's lines side by side, set apart for the zoom: at once the first time, then as it rests
                // (every change to them has MapKit build the map's lines again).
                if open != nil, motion.metersPerPoint == 0 { spaceRoute(context.rect) }
                guard picking else { return }
                heading = context.camera.heading
                if mapSize.width > 0 {
                    let metersPerPoint = context.rect.width * MKMetersPerMapPointAtLatitude(context.rect.origin.coordinate.latitude) / mapSize.width
                    motion.circleDiameter = 2 * Self.cornerMeters / metersPerPoint
                }
                if let middle = proxy.convert(circleSpot, from: .local) { gather(around: middle) }
                // The stops follow a pinch or pan as it happens, not just once it's let go. The badges go along
                // with the map, and are only placed again once it rests: placing them takes longer than a frame.
                guard Date.now.timeIntervalSince(liveRelabelAt) > 0.15 else { return }
                liveRelabelAt = .now
                measure(context.rect, settled: false)
            }
            .onMapCameraChange(frequency: .onEnd) {
                spaceRoute($0.rect)
                moving = false
                drawnCircleLineIDs = circleLineIDs
                visibleRect = $0.rect
                camera = $0.camera
                measure($0.rect, settled: true)
                cull($0.rect)
                if let middle = proxy.convert(circleSpot, from: .local) { gather(around: middle) }
                relabel(proxy)
            }
            // Once the list is up, the circle's middle moves up with it.
            .onChange(of: circleSpot) {
                if let middle = proxy.convert(circleSpot, from: .local) { gather(around: middle) }
            }
            .onGeometryChange(for: CGSize.self, of: \.size) { size in
                let old = mapSize
                mapSize = size
                // A route loaded before the map had its height.
                if !expanded, open != nil, old.height <= 1, size.height > 1 { frameRoute(animated: false) }
            }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { mapFrame = $0 }
            .onChange(of: picking) {
                openedAt = .now
                tucked = false
                // Back from the picker to a stop, the one picked there or the one it opened over: its whole route.
                if !picking, routeToFrame || open != nil { frameRouteSoon() }
            }
            .onChange(of: expanded) {
                // Back to the home screen from full screen: the whole route in its room for it.
                if !expanded, !picking, open != nil { frameRouteSoon() }
            }
            .onChange(of: opened) {
                if opened, let visibleRect { cull(visibleRect) }
            }
            .onChange(of: wantedLayers) { switchLayers(proxy) }
            .task(id: lines.count) {
                // Off the main thread: a city's worth of lines takes a moment.
                let paths = paths
                let spots = await Task.detached(priority: .userInitiated) { LineLabels.spots(for: paths) }.value
                guard !Task.isCancelled else { return }
                labelSpots = spots
                relabel(proxy)
            }
            .onChange(of: selectedID) {
                relabel(proxy)
                // A line picked on the map: its card comes up, tucked away or not.
                if selectedID != nil, tucked { withAnimation(.snappy(duration: 0.3)) { tucked = false } }
            }
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
            // Drawn up once the map is at rest: changing how the lines are drawn has MapKit build them all
            // again, half a second in New York, over and over as the circle moves along under a pinch.
            .onChange(of: circleLineIDs) { if !moving { drawnCircleLineIDs = circleLineIDs } }
            .onChange(of: drawnCircleLineIDs) { relabel(proxy) }
            // Alongside the map's own gestures, which would otherwise swallow a plain tap. At once: a double
            // tap is the map's own, zooming in, as on any map, so its second tap is let be. Not for taps on
            // what lies over the map, which it hears too: the card, the buttons along its top.
            .simultaneousGesture(SpatialTapGesture(coordinateSpace: .global)
                .onEnded { tapped(at: $0.location, proxy: proxy) })
            // Taking no touches, it hears of its taps instead.
            .onChange(of: tap) { if let tap { tapped(at: tap.location, proxy: proxy) } }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { fullHeight = $0 }
        // What lies over the map has moved: the route framed clear of it again.
        .onChange(of: overlaid) { if !expanded, !picking, open != nil { frameRoute(animated: true) } }
        // The card (or the circle's list), over the map's bottom: changing, it leaves the map be. Above
        // the Apple Maps logo, with the close button on top of it, in reach of a thumb. Pulled down, the
        // open map goes back as a sheet would.
        .overlay(alignment: .bottom) {
            if picking {
                VStack(alignment: .trailing, spacing: 0) {
                    if tucked {
                        tuckedBar
                    } else {
                        // Down, out of the way of the map: the card tucks itself away (the pen leaves the picker).
                        Button { tuck(true, from: "button") } label: {
                            Image(systemName: "chevron.down")
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 38, height: 38)
                                .background(.regularMaterial, in: Circle())
                        }
                        .buttonStyle(.borderless)
                        .padding(.horizontal)
                        .accessibilityLabel("Make room for the map")
                        if isCircling {
                            circleList
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .padding()
                        } else {
                            card
                        }
                    }
                }
                .padding(.bottom, Self.logoRoom + bottomInset)
                .contentShape(Rectangle())
                .offset(y: max(cardDrag, 0) * (tucked ? 0.2 : 1))
                .opacity(1 - min(pulled / 120, 1))
                // Pulled down, it tucks away, as the button does; the bar pulled up brings it back.
                .gesture(DragGesture(minimumDistance: 8, coordinateSpace: .global)
                    .onChanged { cardDrag = $0.translation.height }
                    .onEnded { drag in
                        let down = drag.predictedEndTranslation.height
                        if !tucked, drag.translation.height > 60 || down > 160 { tuck(true, from: "pull") }
                        else if tucked, drag.translation.height < -20 || down < -80 { tuck(false, from: "pull") }
                        withAnimation(.spring(duration: 0.3)) { cardDrag = 0 }
                    })
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
                    cardFrame = frame
                    if tucked || !isCircling { cardRoom = frame.height }
                }
                .onDisappear { cardFrame = .null }
                // At the bottom of what shows: on the home screen, the map's bottom is out of sight.
                .padding(.bottom, max(fullHeight - mapHeight, 0))
            }
        }
        .overlay {
            if picking, let error {
                ContentUnavailableView("The map didn't show up either", systemImage: "map", description: Text(error))
                    .background(.regularMaterial)
            } else if picking, lines.isEmpty {
                ProgressView()
            }
        }
        // The city's lines, once they're to show (before they come in): a stop's route alone needs none of them.
        .task(id: wantedLayers.lines) {
            guard wantedLayers.lines, lines.isEmpty else { return }
            error = nil
            // Instantly from the device (or the app's built-in snapshot), then quietly swap in newer
            // data if the proxy has it; that's checked at most once a day. Off the main thread: New
            // York's is big.
            let city = city
            await show(Task.detached(priority: .userInitiated) { Self.prepare(TransitService.cachedLineMap(in: city)) }.value)
            if lines.isEmpty { error = "No line data yet. Your connection is running late too." }
            guard let newer = await TransitService.refreshedLineMap(in: city), !Task.isCancelled else { return }
            await show(Task.detached(priority: .userInitiated) { Self.prepare(newer) }.value)
            error = nil
        }
        .task(id: picking) {
            guard picking, allStops.isEmpty else { return }
            // Thousands of them (New York's buses): read off the main thread.
            let city = city
            allStops = await Task.detached(priority: .userInitiated) { TransitService.cachedStops(in: city) }.value
            if let visibleRect { showStops(in: visibleRect) }
            if let newer = await TransitService.refreshedStops(in: city), !Task.isCancelled {
                allStops = newer
                if let visibleRect { showStops(in: visibleRect) }
            }
        }
        // The open stop: another in the same city keeps the old route up while the new one loads, then
        // glides the camera over to it. Anything else starts afresh.
        .task(id: open) {
            guard let open else { live.clear(); return }
            let fresh = live.selection?.city != open.city || live.stops.isEmpty
            if fresh { live.clear() }
            guard let loaded = await LiveRoute.load(open), !Task.isCancelled else { return }
            // Picked in the picker: framed once it has closed (see `onChange(of: picking)`).
            if picking { routeToFrame = true }
            if fresh {
                live.show(loaded)
                if !picking { frameRoute(animated: false) }
            } else if picking {
                withAnimation(.easeInOut(duration: 0.4)) { live.show(loaded) }
            } else {
                withAnimation(.easeInOut(duration: 0.8)) {
                    live.show(loaded)
                    frameRoute(animated: false)
                }
            }
        }
        // When the map's room changes (how much of it is cut off), frame the route again instead of
        // keeping the old zoom, which would show far too much around it, or cut it off.
        .task(id: shownHeight - cropped) {
            let room = shownHeight - cropped
            guard !expanded, !picking, open != nil else { return }
            // Without a route yet, it'll be framed for this room once it loads.
            guard fittedRoom > 0, abs(fittedRoom - room) > 1 else {
                fittedRoom = room
                return
            }
            frameRoute(animated: true)
        }
        .task {
            while !Task.isCancelled {
                live.now = .currentMinute
                try? await Task.sleep(until: .now + .seconds(live.now.addingTimeInterval(60).timeIntervalSinceNow), clock: .continuous)
            }
        }
        // New positions: each bus snaps to where it was reported, and glides on from there.
        .task(id: Pair(departures, live.tracks.count)) {
            live.glides = Glide.update(live.glides, buses: live.buses(in: departures), tracks: live.tracks, stop: live.selectedStop?.coordinate)
        }
        // Only while one is still on the move: redrawing the map for buses that wait makes its labels flicker.
        .task(id: live.glides) {
            while !Task.isCancelled, live.glides.values.contains(where: { $0.isMoving(at: .now) }) {
                try? await Task.sleep(for: .seconds(1))
                var glide = Transaction(animation: .linear(duration: 1))
                glide[BusLayer.Gliding.self] = true
                withTransaction(glide) { live.tick = .now }
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
            let others = await goingTheSameWay((found ?? []).filter { $0.line != selected.id }, as: picked)
            guard !Task.isCancelled else { return }
            // The lines here by number, then those a walk away (another stop, with its distance) by number.
            withAnimation(.snappy(duration: 0.25)) {
                otherLines = others.sorted {
                    $0.isNearby != $1.isNearby ? !$0.isNearby : $0.line.localizedStandardCompare($1.line) == .orderedAscending
                }
            }
        }
        .task(id: circleCodes) {
            // A moment's rest first: a pan drags stops in and out of the circle.
            try? await Task.sleep(for: .seconds(0.25))
            guard !Task.isCancelled else { return }
            let found = await lookUpCircle(circleCodes)
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.2)) { circleStops = found }
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

    /// The card tucked away: what it's about, in a line, and an arrow to bring it back.
    private var tuckedBar: some View {
        // A tap, not a button: a button would keep a finger swiping it up from the card's drag.
        HStack(spacing: 8) {
            if let selected {
                LineBadge(line: LineBadge.short(selected.id, in: city), font: .system(.subheadline, design: .rounded).weight(.heavy),
                          color: selected.mapColor, textColor: selected.badgeTextColor,
                          round: LineBadge.isRound([selected.id], in: city), spoken: selected.id)
            }
            Text(tuckedTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up").font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal)
        .frame(height: 44)
        .background(.regularMaterial, in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { tuck(false, from: "button") }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Show \(tuckedTitle)")
        .accessibilityAction { tuck(false, from: "button") }
    }

    private var tuckedTitle: String {
        if let selected { return corner.first?.stop.name ?? selected.name }
        if isCircling { return circleCodes.isEmpty ? "Slide the circle over where you wait" : "What stops around here" }
        return recent.isEmpty ? "Tap where you wait" : "Looked at before"
    }

    private func tuck(_ away: Bool, from place: String) {
        Journey.shared.tap(away ? "picker.tuck" : "picker.untuck", place)
        withAnimation(.snappy(duration: 0.3)) { tucked = away }
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
                                Button { Journey.shared.tap("picker.line.switch"); select(line, among: candidates) } label: {
                                    LineBadge(line: LineBadge.short(line.id, in: city), font: .system(.subheadline, design: .rounded).weight(.heavy),
                                              color: line.mapColor, textColor: line.badgeTextColor,
                                              round: LineBadge.isRound([line.id], in: city), spoken: line.id)
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
                            LineBadge(line: LineBadge.short(selected.id, in: city), font: .system(.title3, design: .rounded).weight(.heavy),
                                      color: selected.mapColor, textColor: selected.badgeTextColor,
                                      round: LineBadge.isRound([selected.id], in: city), spoken: selected.id)
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
                            if !stopsAround.isEmpty {
                                // Back to the stops in the circle.
                                Button { Journey.shared.tap("picker.line.close"); withAnimation(.snappy(duration: 0.25)) { deselect() } } label: {
                                    Image(systemName: "arrow.uturn.backward.circle.fill").font(.title2).foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Back to the stops around")
                            }
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
            } else if lines.isEmpty {
                Label("Asking nicely for the lines…", systemImage: "hand.tap")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if !recent.isEmpty {
                recentStops
            } else {
                Label(stopsAround.isEmpty ? "Tap where you wait to zoom in." : "Tap your stop, or your line.", systemImage: "hand.tap")
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

    /// The stops looked at here before and not kept (see `Selection.recent`), newest first.
    private var recent: [Selection] { Selection.recent.filter { $0.city == city } }
    /// How tall a row of them is, at this text size: the list shows two, and scrolls for more.
    @ScaledMetric private var recentRow: CGFloat = 46

    /// Those stops, a tap away from being picked again.
    private var recentStops: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Looked at before").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(recent) { stop in
                        Button {
                            Journey.shared.tap("picker.recent")
                            onPick(stop)
                        } label: {
                            HStack(spacing: 10) {
                                LineBadges(parts: stop.badgeParts, font: .system(.subheadline, design: .rounded).weight(.heavy), round: stop.roundBadge)
                                    .lineLimit(1)
                                    .fixedSize()
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(stop.stopName).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text("To \(stop.destination)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .frame(minHeight: recentRow)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(stop.lineLabel) at \(stop.stopName), to \(stop.destination)")
                    }
                }
            }
            // Two rows' room, however many there are; the rest scroll up into it.
            .frame(height: recentRow * CGFloat(min(recent.count, 2)))
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(recent.count > 2 ? .visible : .hidden)
        }
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
        return Button { Journey.shared.tap("picker.direction"); withAnimation(.snappy(duration: 0.2)) { picked = arrow } } label: {
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
                                LineBadge(line: LineBadge.short(other.line, in: city), font: .system(.subheadline, design: .rounded).weight(.heavy),
                                          color: mapLine?.mapColor ?? LineBadge.red, textColor: mapLine?.badgeTextColor ?? .white,
                                          round: LineBadge.isRound([other.line], in: city), spoken: other.line)
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

    /// `lines` without those at the picked stop that leave it the other way, or hardly leave it at
    /// all: a stop served both ways (as some of Seattle's are) lists the lines going back where the
    /// picked one came from too, and those ending there or at the next stop (3rd Ave S & S Main St is
    /// where the 40 to Downtown ends). Those a walk away already face the same way; a line whose way
    /// can't be told stays.
    private func goingTheSameWay(_ lines: [StopLine], as picked: StopArrow) async -> [StopLine] {
        guard let ours = Self.leavingBearing(at: picked.stop.code, along: picked.direction) else { return lines }
        var kept: [StopLine] = []
        for other in lines {
            guard !other.isNearby else { kept.append(other); continue }
            let line = Line(id: other.line, name: "", mode: "bus")
            var directions = TransitService.cachedDirections(for: line, in: city)
            if directions == nil { directions = try? await TransitService.directions(for: line, in: city) }
            let stop = other.stop ?? picked.stop.code
            let way = directions?.first { $0.id == other.direction && $0.stops.contains { $0.code == stop } }
            guard let way, let theirs = Self.leavingBearing(at: stop, along: way),
                  let here = way.stops.firstIndex(where: { $0.code == stop }) else { kept.append(other); continue }
            // Two stops to go at least, unless its one stop to go is on ours too (to the World Trade Center
            // from Exchange Place, where both PATH lines end).
            let left = way.stops.count - here - 1
            let endsWithUs = left == 1 && picked.direction.stops.contains { $0.code == way.stops[here + 1].code }
            if left > 1 || endsWithUs, abs((theirs - ours + 540).truncatingRemainder(dividingBy: 360) - 180) <= 100 { kept.append(other) }
        }
        return kept
    }

    /// Which way `direction` heads from `stop`: toward its next stop (from the one before, at the end).
    static func leavingBearing(at stop: String, along direction: Direction) -> Double? {
        let stops = direction.stops
        guard let i = stops.firstIndex(where: { $0.code == stop }), let here = stops[i].coordinate else { return nil }
        if i + 1 < stops.count, let next = stops[i + 1].coordinate { return bearingBetween(here, next, ifSame: nil) }
        if i > 0, let previous = stops[i - 1].coordinate { return bearingBetween(previous, here, ifSame: nil) }
        return nil
    }

    /// "80 m", to the nearest 10 m.
    private func walkLabel(_ line: StopLine) -> String {
        "\(max(10, Int((Double(line.distance ?? 0) / 10).rounded()) * 10)) m"
    }

    /// An arrow at the picked stop picks that direction. Along the selected line (or on one of its
    /// stops), its stop nearest the tap. Anywhere else, zoomed out too far for stops, it zooms in
    /// there; closer, the circle goes there, letting go of the line: lines are picked from the
    /// circle's list. (Picking the line nearest a tap had people in New York, where a fingertip
    /// always covers one, hopping from line to line without ever seeing the circle.)
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
        // A stop dot: the selected line's own moves its stop there; any other takes the circle there.
        if let stop = shownStops
            .compactMap({ stop -> (MapStop, CGFloat)? in
                guard let spot = proxy.convert(stop.coordinate, to: .local) else { return nil }
                let distance = hypot(spot.x - point.x, spot.y - point.y)
                return distance <= 16 ? (stop, distance) : nil
            })
            .min(by: { $0.1 < $1.1 })?.0 {
            if selectedID != nil, arrows.contains(where: { $0.stop.code == stop.code }) {
                tapCoordinate = stop.coordinate
                withAnimation(.snappy(duration: 0.25)) { pickCorner(near: stop.coordinate) }
                return
            }
            circle(on: stop.coordinate, proxy: proxy)
            return
        }
        tapCoordinate = coordinate
        if let selectedID, !arrows.isEmpty,
           (paths[selectedID] ?? []).map({ distanceToPath(coordinate, $0) }).min() ?? .infinity <= meters(coordinate, edge) {
            withAnimation(.snappy(duration: 0.25)) { pickCorner(near: coordinate) }
            return
        }
        // Zoomed out too far for the stops, a tap zooms in there.
        guard !stopsAround.isEmpty else {
            Journey.shared.tap("picker.map.zoom")
            return zoomIn(at: point, proxy: proxy)
        }
        circle(on: coordinate, proxy: proxy)
    }

    /// Lets go of the selected line, if any, and takes the circle to `coordinate`, to list what stops there.
    private func circle(on coordinate: CLLocationCoordinate2D, proxy: MapProxy) {
        if selectedID != nil { withAnimation(.snappy(duration: 0.25)) { deselect() } }
        center(on: coordinate, proxy: proxy)
    }

    /// Zooms in twice as close, the spot tapped staying under the finger.
    private func zoomIn(at point: CGPoint, proxy: MapProxy) {
        guard let visibleRect, let coordinate = proxy.convert(point, from: .local) else { return }
        let spot = MKMapPoint(coordinate)
        let rect = MKMapRect(x: spot.x - (spot.x - visibleRect.minX) / 2, y: spot.y - (spot.y - visibleRect.minY) / 2,
                             width: visibleRect.width / 2, height: visibleRect.height / 2)
        withAnimation(.smooth(duration: 0.35)) { position = .rect(rect) }
    }

    /// `size`, or smaller (a fifth at a time) until few enough stops are around `coordinate` for them
    /// to show (see `showStops`), down to 600 m across.
    private func sizeShowingStops(around coordinate: CLLocationCoordinate2D, from size: MKMapSize) -> MKMapSize {
        let center = MKMapPoint(coordinate)
        let metersPerMapPoint = MKMetersPerMapPointAtLatitude(coordinate.latitude)
        func fewEnoughStops(_ size: MKMapSize) -> Bool {
            let rect = MKMapRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
            return size.width * metersPerMapPoint / mapSize.width < Self.stopsConsideredBelowMetersPerPoint
                && allStops.lazy.filter { rect.contains(MKMapPoint($0.coordinate)) }.count <= Self.mostStopsInView
        }
        var size = size
        while !fewEnoughStops(size) && size.width * metersPerMapPoint > 600 {
            size = MKMapSize(width: size.width * 0.8, height: size.height * 0.8)
        }
        return size
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

    /// Notes how zoomed in the map is, for the stop dots: in `metersPerPoint` only once it's `settled`, as
    /// what the map shows depends on it, and changing it as the map moves would have all of it gone over
    /// again, several times a second.
    private func measure(_ rect: MKMapRect, settled: Bool) {
        guard mapSize.width > 0 else { return }
        let meters = rect.width * MKMetersPerMapPointAtLatitude(rect.origin.coordinate.latitude) / mapSize.width
        if settled { metersPerPoint = meters }
        motion.circleDiameter = 2 * Self.cornerMeters / meters
        showStops(in: rect, metersPerPoint: meters)
    }

    /// Sets the route's lines on a shared track apart for the zoom `rect` shows, if it has changed enough to see.
    private func spaceRoute(_ rect: MKMapRect) {
        guard open != nil, mapSize.width > 0 else { return }
        let meters = rect.width * MKMetersPerMapPointAtLatitude(rect.origin.coordinate.latitude) / mapSize.width
        if abs(meters - motion.metersPerPoint) > motion.metersPerPoint * 0.02 { motion.metersPerPoint = meters }
    }

    /// The middle of the map that the card or the circle's list leaves showing, where the circle goes.
    private var circleSpot: CGPoint {
        CGPoint(x: mapSize.width / 2, y: (cropped + clearBottom) / 2)
    }

    /// The stops within the circle around `middle`, nearest first.
    private func gather(around middle: CLLocationCoordinate2D) {
        let codes = stopsAround
            .map { ($0.code, meters($0.coordinate, middle)) }
            .filter { $0.1 <= Self.cornerMeters }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        if codes != circleCodes { circleCodes = codes }
    }

    /// Slides the map so `coordinate` is under the circle, as far in as it is now.
    /// Closer in, if that's what it takes for the stops there to show, and with them the circle.
    private func center(on coordinate: CLLocationCoordinate2D, proxy: MapProxy) {
        guard let camera, let visibleRect, let middle = proxy.convert(CGPoint(x: mapSize.width / 2, y: shownHeight / 2), from: .local),
              let spot = proxy.convert(circleSpot, from: .local)
        else { return }
        let zoom = sizeShowingStops(around: coordinate, from: visibleRect.size).width / visibleRect.width
        // The circle is above the map's middle by this much (less, closer in); the camera's center goes
        // that much below the stop.
        let shift = CLLocationCoordinate2D(latitude: (middle.latitude - spot.latitude) * zoom,
                                           longitude: (middle.longitude - spot.longitude) * zoom)
        withAnimation(.smooth(duration: 0.4)) {
            position = .camera(MapCamera(
                centerCoordinate: CLLocationCoordinate2D(latitude: coordinate.latitude + shift.latitude,
                                                         longitude: coordinate.longitude + shift.longitude),
                distance: camera.distance * zoom, heading: camera.heading, pitch: camera.pitch))
        }
    }

    /// The lines and directions at each of `codes`, in that order: which lines stop where comes with
    /// the stops, or else from the proxy (Muni's, from the live times); each line's directions that
    /// call there (from the device, or downloaded once) give the way it goes and the stop's name.
    private func lookUpCircle(_ codes: [String]) async -> [CircleStop] {
        let stops = codes.compactMap { code in stopsAround.first { $0.code == code } }
        var linesAt = Dictionary(stops.compactMap { s in s.lines.map { (s.code, $0) } }, uniquingKeysWith: { a, _ in a })
        let asking = stops.filter { $0.lines == nil }.map(\.code)
        if !asking.isEmpty, let found = try? await TransitService.linesAtStops(asking, in: city) {
            for line in found where !(linesAt[line.stop ?? asking[0]] ?? []).contains(line.line) {
                linesAt[line.stop ?? asking[0], default: []].append(line.line)
            }
        }
        let wanted = Set(linesAt.values.flatMap { $0 })
            .filter { circleDirections[$0] == nil }
            .compactMap { id in lines.first { $0.id == id } }
        let city = city
        let loaded = await withTaskGroup(of: (String, [Direction]).self) { group in
            for line in wanted {
                group.addTask {
                    var loaded = TransitService.cachedDirections(for: line.line, in: city)
                    if loaded == nil { loaded = try? await TransitService.directions(for: line.line, in: city) }
                    return (line.id, loaded ?? [])
                }
            }
            var all: [String: [Direction]] = [:]
            for await (id, loaded) in group { all[id] = loaded }
            return all
        }
        circleDirections.merge(loaded) { _, new in new }
        let directions = circleDirections
        // Each way from each stop, by the stop's name: the two sides of a street (or the corners of
        // an intersection) that share one are one place to riders.
        var byName: [(name: String, ways: [CircleWay])] = []
        for stop in stops {
            for id in linesAt[stop.code] ?? [] {
                guard let line = lines.first(where: { $0.id == id }) else { continue }
                for direction in directions[id] ?? [] {
                    // Not where it ends: nobody gets on there.
                    guard let i = direction.stops.firstIndex(where: { $0.code == stop.code }), i < direction.stops.count - 1
                    else { continue }
                    let name = direction.stops[i].name
                    let way = CircleWay(line: line, direction: direction, stop: stop.code, stopName: name, coordinate: stop.coordinate)
                    if let at = byName.firstIndex(where: { $0.name == name }) {
                        if !byName[at].ways.contains(way) { byName[at].ways.append(way) }
                    } else {
                        byName.append((name, [way]))
                    }
                }
            }
        }
        return byName.map { name, ways in
            CircleStop(name: name, codes: Set(ways.map(\.stop)), ways: ways.sorted {
                $0.line.id != $1.line.id ? $0.line.id.localizedStandardCompare($1.line.id) == .orderedAscending
                                         : $0.direction.destination < $1.direction.destination
            })
        }
    }

    /// The lines stopping in the circle, a row each, nearest stop first: where it runs between and
    /// the stop it's caught at. Not a row per way: a stop's sides often go by different names
    /// (Muni's "Castro Station/Downtown" and "/Outbound"), and which way comes next anyway, on the
    /// stop's card, with an arrow and the minutes for each (or right away, for a line going only one
    /// way from here).
    private var circleList: some View {
        let lines = circleLines
        return VStack(alignment: .leading, spacing: 8) {
            Text(circleCodes.isEmpty ? "Slide the circle over where you wait." : "What stops around here")
                .font(.subheadline).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(lines, id: \.first!.line.id) { ways in
                        let line = ways[0].line
                        let ends = ways.map(\.direction.destination).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                        Button { pick(ways) } label: {
                            HStack(spacing: 10) {
                                LineBadge(line: LineBadge.short(line.id, in: city), font: .system(.subheadline, design: .rounded).weight(.heavy),
                                          color: line.mapColor, textColor: line.badgeTextColor,
                                          round: LineBadge.isRound([line.id], in: city), spoken: line.id)
                                    .fixedSize()
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(ends.count == 1 ? "To \(ends[0])" : ends.prefix(2).joined(separator: " ↔ "))
                                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text(ways[0].stopName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Line \(line.id) to \(ends.joined(separator: " or ")), at \(ways[0].stopName)")
                    }
                    if !circleCodes.isEmpty, lines.isEmpty {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { circleRowsHeight = $0 }
            }
            // As tall as its rows, up to the most (see `circleListHeight`), then it scrolls.
            .frame(height: min(circleRowsHeight, Self.circleListHeight - 28))
            .scrollBounceBehavior(.basedOnSize)
        }
        .animation(.snappy(duration: 0.2), value: circleRowsHeight)
    }

    /// The ways from the stops in the circle, a group per line, in the order of their nearest stop.
    private var circleLines: [[CircleWay]] {
        circleStops.filter { !$0.codes.isDisjoint(with: circleCodes) }.flatMap(\.ways)
            .reduce(into: [[CircleWay]]()) { groups, way in
                if let i = groups.firstIndex(where: { $0[0].line.id == way.line.id }) { groups[i].append(way) } else { groups.append([way]) }
            }
    }

    /// Picks a line from the circle's list, at its stop there: going one way, that way too.
    private func pick(_ ways: [CircleWay]) {
        guard let first = ways.first else { return }
        Journey.shared.tap("picker.circle.line", ways.count == 1 ? "one way" : "both ways")
        tapCoordinate = first.coordinate
        select(first.line, among: [first.line], way: ways.count == 1 ? (first.direction.id, first.stop) : nil)
    }

    /// The stops in (and just around) `rect`. On the map, those closer together on screen than a dot or
    /// so as one: the map split into squares about that size, one stop for each square with any. The
    /// squares stay put as the map moves, and only halve or double as it zooms, so the dots don't keep
    /// changing (every change has MapKit draw the whole map's lines again). None with too many squares
    /// in view, where they'd bury the lines. For the circle, every one of them, once few enough are in
    /// view to tell apart: sooner where stops are sparse (out in the suburbs, along a ferry route) than
    /// downtown.
    private func showStops(in rect: MKMapRect, metersPerPoint: Double? = nil) {
        let metersPerPoint = metersPerPoint ?? self.metersPerPoint
        let area = rect.insetBy(dx: -rect.width * 0.15, dy: -rect.height * 0.15)
        let nearby = picking && mapSize.width > 0 && metersPerPoint < Self.stopsConsideredBelowMetersPerPoint
            ? allStops.filter { area.contains(MKMapPoint($0.coordinate)) } : []
        let inView = nearby.lazy.filter { rect.contains(MKMapPoint($0.coordinate)) }.count
        let around = inView <= Self.mostStopsInView ? nearby : []
        if around.map(\.code) != stopsAround.map(\.code) { stopsAround = around }

        // The same dots while the map shows what they were chosen for, as closely zoomed.
        let square = Self.dotSpacing * pow(2, (log2(rect.width / max(mapSize.width, 1))).rounded(.up))
        guard nearby.isEmpty || square != dotsSquare || dotsArea?.contains(rect) != true else { return }
        dotsArea = nearby.isEmpty ? nil : area
        dotsSquare = square
        // Where that leaves too many, as downtown, squares twice as large.
        var shown: [MapStop] = []
        // Once dots show, larger squares still, rather than none: right after the squares halve, as the map
        // zooms in, there are as many as four times the dots for a moment, which would have them all go,
        // and come back a little further in.
        let tries = shownStops.isEmpty ? Self.largerSquares : Self.largerSquares + 2
        for size in (0..<tries).map({ square * pow(2, Double($0)) }) {
            var dots: [SIMD2<Int>: MapStop] = [:]
            for stop in nearby {
                let spot = MKMapPoint(stop.coordinate)
                let key = SIMD2(Int((spot.x / size).rounded(.down)), Int((spot.y / size).rounded(.down)))
                if let kept = dots[key], kept.code <= stop.code { continue }
                dots[key] = stop
            }
            if dots.count <= Self.mostDotsAround {
                shown = dots.values.sorted { $0.code < $1.code }
                break
            }
        }
        // Too many even so: looked at again as it moves, until there are few enough.
        if shown.isEmpty { dotsArea = nil }
        if shown.map(\.code) != shownStops.map(\.code) { shownStops = shown }
    }

    /// Every stop around shows, for the circle, once no more than this many are in view.
    private static let mostStopsInView = 120
    /// Stops closer together on screen than this (in points, up to twice as far) show as one dot.
    private static let dotSpacing = 12.0
    /// The most dots in and just around the map's view (about 1.7 times its area), and the sizes of
    /// square tried to get there (each twice the last) before there are none: larger, a dot would stand
    /// for stops too far apart to mean anything.
    private static let mostDotsAround = 150
    private static let largerSquares = 2
    /// Further out than this (a few miles across), they aren't even counted.
    private static let stopsConsideredBelowMetersPerPoint = 30.0

    /// How far the circle reaches from its middle: as far as "Also fine with" looks (the proxy's
    /// NEARBY_METERS), a minute or two on foot.
    private static let cornerMeters = 150.0

    /// Stops along a line are a few hundred meters apart; this far in, that's a fingertip or more.
    private static let dotsBelowMetersPerPoint = 6.0

    /// Selects `line` and its stop nearest the last tap together, once its stops are at hand, so the
    /// card and map change once, straight from the old line to the new one. Stops seen before are on
    /// the device already; others need one download, during which the old line stays up.
    private func select(_ line: MapLine, among nearby: [MapLine], way: (direction: String, stop: String)? = nil) {
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
                if let way, let arrow = lineArrows.first(where: { $0.direction.id == way.direction && $0.stop.code == way.stop }) {
                    if !corner.contains(arrow) { corner = StopArrow.corner(near: arrow.position, in: lineArrows) }
                    picked = corner.first { $0.id == arrow.id } ?? arrow
                }
            }
        }
        if let cached = TransitService.cachedDirections(for: line.line, in: city) { return show(cached) }
        lineLoad = Task {
            guard let loaded = try? await TransitService.directions(for: line.line, in: city), !Task.isCancelled else { return }
            show(loaded)
        }
    }

    /// Places the line badges for what the map shows now.
    private func relabel(_ proxy: MapProxy, showing rect: MKMapRect? = nil) {
        // Without the city's lines, none: those showing fade out.
        let placed: [LineLabel]
        if !layers.lines {
            placed = []
        } else {
            guard let visibleRect = rect ?? visibleRect, mapSize.width > 0, !labelSpots.isEmpty else { return }
            let metersPerPoint = visibleRect.width * MKMetersPerMapPointAtLatitude(visibleRect.origin.coordinate.latitude) / mapSize.width
            // Clear of the edges, so no badge is cut off.
            let bounds = CGRect(x: 0, y: cropped, width: mapSize.width, height: clearBottom - cropped).insetBy(dx: 8, dy: 6)
            let circled = drawnCircleLineIDs
            placed = LineLabels.place(
                lines: lines.filter { circled.isEmpty ? culledIDs.contains($0.id) : circled.contains($0.id) }, spots: labelSpots, excluding: alsoLineIDs.union([selectedID].compactMap { $0 }),
                previous: labels, visible: visibleRect, bounds: bounds, metersPerPoint: metersPerPoint,
                convert: { proxy.convert($0, to: .local) })
        }
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

    /// A city's line map made ready to draw, off the main thread: each line's paths, extent and tier.
    struct Prepared: @unchecked Sendable {
        let lines: [MapLine]
        let paths: [String: [[CLLocationCoordinate2D]]]
        /// The pieces each line is drawn in, made once: given the same ones again with only another
        /// color or width, MapKit keeps them rather than building them anew (ferries dashed, see `LineLayer.dashed`).
        let polylines: [String: [MKPolyline]]
        /// The same, but the ferries in dashes four times as long, further out: a dash is a piece of its own,
        /// and in the 300-meter ones New York's ferries come to a thousand of them, which MapKit builds again
        /// with every change to the lines. The other lines' are the same pieces.
        let farPolylines: [String: [MKPolyline]]
        let bounds: [String: MKMapRect]
        let tiers: [String: Int]
    }

    nonisolated static func prepare(_ loaded: [MapLine]) -> Prepared {
        var paths: [String: [[CLLocationCoordinate2D]]] = [:], bounds: [String: MKMapRect] = [:], tiers: [String: Int] = [:]
        var polylines: [String: [MKPolyline]] = [:], farPolylines: [String: [MKPolyline]] = [:]
        for line in loaded {
            let path = line.shapes.map { $0.compactMap { $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil } }
            paths[line.id] = path
            let pieces = (line.mode == "ferry" ? path.flatMap { LineLayer.dashed($0) } : path).map { MKPolyline(coordinates: $0, count: $0.count) }
            polylines[line.id] = pieces
            farPolylines[line.id] = line.mode == "ferry"
                ? path.flatMap { LineLayer.dashed($0, on: 1200, off: 880) }.map { MKPolyline(coordinates: $0, count: $0.count) } : pieces
            bounds[line.id] = path.joined().reduce(MKMapRect.null) { $0.union(MKMapRect(origin: MKMapPoint($1), size: MKMapSize())) }
            tiers[line.id] = LineLabels.tier(of: line)
        }
        return Prepared(lines: loaded, paths: paths, polylines: polylines, farPolylines: farPolylines, bounds: bounds, tiers: tiers)
    }

    private func show(_ loaded: Prepared) {
        guard !loaded.lines.isEmpty else { return }
        paths = loaded.paths
        polylines = loaded.polylines
        farPolylines = loaded.farPolylines
        lineBounds = loaded.bounds
        lineTiers = loaded.tiers
        pathsVersion += 1
        lines = loaded.lines
        // A refresh may have dropped the selected line (a service change); let go of it then.
        if let selectedID, !loaded.lines.contains(where: { $0.id == selectedID }) { deselect() }
        cull(visibleRect ?? {
            let region = city.region
            let a = MKMapPoint(CLLocationCoordinate2D(latitude: region.center.latitude + region.span.latitudeDelta / 2,
                                                      longitude: region.center.longitude - region.span.longitudeDelta / 2))
            let b = MKMapPoint(CLLocationCoordinate2D(latitude: region.center.latitude - region.span.latitudeDelta / 2,
                                                      longitude: region.center.longitude + region.span.longitudeDelta / 2))
            return MKMapRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        }())
    }

    /// Keeps the lines in and around `rect` that the zoom can tell apart: zoomed out to the city, its
    /// backbone (trains, rapid and select buses: tier 0); the regular lines across a few
    /// neighborhoods; express and owl lines close in. Those coming in blend in.
    private func cull(_ rect: MKMapRect) {
        guard !lines.isEmpty, mapSize.width > 0 else { return }
        let metersPerPoint = rect.width * MKMetersPerMapPointAtLatitude(rect.origin.coordinate.latitude) / mapSize.width
        let tier = metersPerPoint < Self.allLinesBelowMetersPerPoint ? 2 : metersPerPoint < Self.linesBelowMetersPerPoint ? 1 : 0
        // The same lines while the map stays within what they were chosen for, as far in: any change has
        // MapKit build every line on the map again, half a second in New York.
        if tier == culledFor.tier, culledFor.lines == lines.count, let area = culledFor.area, area.contains(rect) { return }
        let around = rect.insetBy(dx: -rect.width * 0.75, dy: -rect.height * 0.75)
        culledFor = (around, tier, lines.count)
        let culled = Set(lines.lazy.map(\.id).filter { (lineTiers[$0] ?? 1) <= tier && lineBounds[$0]?.intersects(around) == true })
        // The ferries' dashes: the longer ones but closest in; only those around the view, but for the city as a whole.
        let far = tier < 2, area: MKMapRect? = tier == 0 ? nil : around
        guard culled != culledIDs || far != farFerries || !LineLayer.same(area, ferryArea) else { return }
        let change = { culledIDs = culled; farFerries = far; ferryArea = area }
        // Lines coming and going as the map comes to rest blend; not before any are on it.
        if layers.lines, !visibleLineIDs.isEmpty { fader.blend(at: rect, change) } else { change() }
    }

    /// Zoomed out further than this, only the backbone; then the regular lines; then all.
    private static let linesBelowMetersPerPoint = 14.0
    private static let allLinesBelowMetersPerPoint = 5.0

    /// Switches the layers to `wantedLayers`. The city's lines coming in over the route wait for the
    /// picker to open out; lines coming or going, and the picker's own going, blend (see `MapFader`).
    private func switchLayers(_ proxy: MapProxy) {
        switching?.cancel()
        switching = nil
        let wanted = wantedLayers
        var now = wanted
        if wanted.lines, !layers.lines, layers.route { now.lines = false }
        show(now, proxy)
        guard now != wanted else { return }
        switching = Task {
            try? await Task.sleep(for: .seconds(0.45))
            guard !Task.isCancelled else { return }
            show(wanted, proxy)
        }
    }

    private func show(_ new: MapLayers, _ proxy: MapProxy) {
        let old = layers
        guard new != old else { return }
        let change = {
            if old.picking, !new.picking {
                deselect()
                stopsAround = []
                shownStops = []
                dotsArea = nil
                circleCodes = []
            }
            if old.lines, !new.lines {
                labels = []
                leavingLabels = [:]
            }
            layers = new
            relabel(proxy)
        }
        if old.lines != new.lines || old.picking && !new.picking { fader.blend(at: motion.shown, change) } else { change() }
    }

    /// Makes the map as tall as `wantedHeight` asks, with it just where it is: the same top, as far in.
    /// MapKit keeps a map's middle as it changes size, and resizes a moment after SwiftUI says, so under
    /// a picture of the map, the places at its top corners are noted, the height changed, and the camera
    /// moved and zoomed until they're back, before the picture fades.
    private func keepClear(_ proxy: MapProxy) {
        let wanted = wantedHeight
        guard abs(wanted - mapHeight) > 0.5 else { return }
        keeping?.cancel()
        // Otherwise (the page settling, the home screen's room changing), what shows is framed afresh.
        guard expanded || expanded != sizedExpanded else {
            mapHeight = wanted
            if open != nil { frameRoute(animated: false) }
            return
        }
        sizedExpanded = expanded
        let corners = (CGPoint(x: 0, y: 0), CGPoint(x: mapSize.width, y: 0))
        guard mapSize.width > 0, mapSize.height > 1, let left = proxy.convert(corners.0, from: .local), let right = proxy.convert(corners.1, from: .local) else {
            mapHeight = wanted
            return
        }
        let held = fader.hold()
        mapHeight = wanted
        keeping = Task {
            await fader.settled(at: wanted)
            // The same top corner, as far in, as tall as it is now: an area, which MapKit fits exactly
            // (a camera's distance shows more or less depending on the map's height as MapKit last saw it).
            let start = MKMapPoint(left), across = MKMapPoint(right).x - start.x
            for attempt in 0..<4 {
                guard !Task.isCancelled, mapSize.width > 0 else { break }
                let perPoint = across / mapSize.width
                let rect = MKMapRect(x: start.x, y: start.y, width: across, height: mapSize.height * perPoint)
                // The same area set again wouldn't move the map: as a region the next time.
                position = attempt % 2 == 0 ? .rect(rect) : .region(MKCoordinateRegion(rect))
                try? await Task.sleep(for: .milliseconds(80))
                guard let now = proxy.convert(corners.0, from: .local) else { break }
                let off = hypot(MKMapPoint(now).x - start.x, MKMapPoint(now).y - start.y)
                if off < perPoint * 0.5 { break }
            }
            fader.release(held)
        }
    }

    /// A tap on the map, where it landed in the window: the picker's, past the card and what's along the top.
    private func tapped(at location: CGPoint, proxy: MapProxy) {
        let now = Date.now
        defer { tappedAt = now }
        guard picking, opened, now.timeIntervalSince(openedAt) > 0.4, now.timeIntervalSince(tappedAt) > 0.35,
              !cardFrame.contains(location), location.y > mapFrame.minY + cropped + topInset,
              location.y < mapFrame.minY + shownHeight
        else { return }
        Journey.shared.tap("picker.map.tap", selectedID == nil ? nil : "with a line")
        handleTap(at: CGPoint(x: location.x - mapFrame.minX, y: location.y - mapFrame.minY), proxy: proxy)
    }

    /// Frames the open stop's route, animated, once what shows has settled: the map's new height too
    /// (see `keepClear`), which would otherwise put back what it showed before.
    private func frameRouteSoon() {
        routeToFrame = false
        Task {
            try? await Task.sleep(for: .seconds(0.1))
            await keeping?.value
            frameRoute(animated: true)
        }
    }

    /// Frames the open stop's route in the part of the map that shows: below `topInset` and what's cut off.
    private func frameRoute(animated: Bool) {
        guard let route = live.bounds, mapSize.width > 0, mapSize.height > 1 else { return }
        // Not for a size MapKit's map hasn't got yet: once it has.
        if let actual = fader.mapHeight, abs(actual - mapSize.height) > 0.5 {
            let height = mapSize.height
            Task {
                await fader.settled(at: height)
                frameRoute(animated: animated)
            }
            return
        }
        fittedRoom = shownHeight - cropped
        let band = min(cropped + topInset, shownHeight - 1)...max(shownHeight - bottomInset, cropped + topInset + 1)
        let across = min(leadingInset, mapSize.width - 1)...mapSize.width
        let rect = LiveRoute.frame(route, in: CGSize(width: mapSize.width, height: shownHeight), band: band, across: across)
        // The same frame as a region when it's already this rect: setting an equal position again
        // wouldn't move the camera.
        let framed: MapCameraPosition = position == .rect(rect) ? .region(MKCoordinateRegion(rect)) : .rect(rect)
        if animated { withAnimation(.smooth(duration: 0.6)) { position = framed } } else { position = framed }
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
        Journey.shared.tap("picker.choose", also.isEmpty ? "map" : "map with \(also.count) more")
        onPick(Selection(
            lineID: selected.id, lineName: selected.name, directionID: arrow.direction.id,
            destination: arrow.direction.destination, stopCode: arrow.stop.code, stopName: arrow.stop.name,
            city: city, also: also))
    }

    /// Adding a line zooms out to show all of it and its stops; removing the last one goes back to
    /// exactly where the map was before.
    private func toggleAlso(_ other: StopLine) {
        Journey.shared.tap("picker.also", alsoIDs.contains(other.id) ? "remove" : other.isNearby ? "add nearby" : "add")
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
        // Clear of the card over the map's bottom.
        let framed = LiveRoute.frame(rect.insetBy(dx: -pad, dy: -pad), in: CGSize(width: mapSize.width, height: shownHeight),
                                     band: min(cropped, clearBottom - 1)...clearBottom)
        withAnimation(.smooth(duration: 0.6)) {
            position = .rect(framed)
        }
    }
}

/// The picker's circle, as large as the map's zoom has it (see `MapMotion`).
private struct PickerCircle: View {
    let motion: MapMotion

    var body: some View {
        Circle()
            .fill(Color.accentColor.opacity(0.12))
            .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 2)
            .frame(width: motion.circleDiameter, height: motion.circleDiameter)
    }
}

/// What's on the home map, each layer switched on and off on its own.
struct MapLayers: Equatable {
    /// The open stop's route, its stop and the buses on their way to it (`RouteLayer`, `BusLayer`).
    var route = false
    /// The city's lines, as many as the zoom tells apart, with their names (`LineLayer`, `cull`).
    var lines = false
    /// The stop picker's own: stops once zoomed in, the circle, the selected line's stops and arrows.
    var picking = false

    /// A stop's route when one is open; the city's lines when none is, or opened out into the picker,
    /// with the picker's own.
    init(open: Selection?, opened: Bool) {
        route = open != nil
        lines = open == nil || opened
        picking = opened
    }
}

/// Blends what changes on a map: a picture of it as it is goes over it, the change is made under the
/// picture, and the picture fades out. Changing the color of hundreds of a map's lines, step by step,
/// has MapKit build them all again at each step, which takes it seconds; this way they're built once,
/// and the fade runs on its own, even while MapKit is busy. A map moved under the picture (a pan
/// as it fades) has it go at once.
@MainActor
final class MapFader {
    fileprivate weak var host: UIView?
    private var cover: UIView?
    private var coveredRect: MKMapRect?

    /// Makes `change` under a picture of the map, as it shows `rect`, and fades the picture.
    func blend(at rect: MKMapRect?, _ change: () -> Void) {
        drop()
        guard let host, let map = Self.map(under: host), let picture = map.snapshotView(afterScreenUpdates: false) else {
            return change()
        }
        picture.frame = map.convert(map.bounds, to: host)
        picture.isUserInteractionEnabled = false
        host.addSubview(picture)
        cover = picture
        coveredRect = rect
        change()
        // Once MapKit has drawn the change (the main thread is busy until it has).
        Task {
            try? await Task.sleep(for: .seconds(0.12))
            guard cover === picture else { return }
            UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut]) { picture.alpha = 0 } completion: { _ in
                picture.removeFromSuperview()
                if self.cover === picture { self.cover = nil }
            }
        }
    }

    /// A picture of the map over it, for as long as it takes to put the map back where it was: not
    /// taken away when the map moves, as it will. `release` fades it.
    func hold() -> UIView? {
        drop()
        guard let host, let map = Self.map(under: host), let picture = map.snapshotView(afterScreenUpdates: false) else { return nil }
        picture.frame = map.convert(map.bounds, to: host)
        picture.isUserInteractionEnabled = false
        host.addSubview(picture)
        cover = picture
        coveredRect = nil
        return picture
    }

    func release(_ picture: UIView?) {
        guard let picture, cover === picture else { return }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseInOut]) { picture.alpha = 0 } completion: { _ in
            picture.removeFromSuperview()
            if self.cover === picture { self.cover = nil }
        }
    }

    /// How tall MapKit's own map is: it changes size a moment after SwiftUI says it has.
    var mapHeight: CGFloat? {
        guard let host, let map = Self.map(under: host) else { return nil }
        return map.bounds.height
    }

    /// Until MapKit's map is `height` points tall (or a moment has passed).
    func settled(at height: CGFloat) async {
        for _ in 0..<20 {
            if let now = mapHeight, abs(now - height) < 0.5 { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// The map moved: a picture over it would be out of place.
    func moved(to rect: MKMapRect) {
        guard cover != nil, let coveredRect else { return }
        let tolerance = coveredRect.width * 0.002
        if abs(rect.minX - coveredRect.minX) > tolerance || abs(rect.minY - coveredRect.minY) > tolerance
            || abs(rect.width - coveredRect.width) > tolerance { drop() }
    }

    private func drop() {
        cover?.layer.removeAllAnimations()
        cover?.removeFromSuperview()
        cover = nil
    }

    /// The map `host` lies over.
    private static func map(under host: UIView) -> MKMapView? {
        guard let window = host.window else { return nil }
        let frame = host.convert(host.bounds, to: window)
        var best: (map: MKMapView, area: CGFloat)?
        var views: [UIView] = [window]
        while let view = views.popLast() {
            if let map = view as? MKMapView {
                let overlap = map.convert(map.bounds, to: window).intersection(frame)
                if !overlap.isNull, overlap.width * overlap.height > best?.area ?? 0 { best = (map, overlap.width * overlap.height) }
                continue
            }
            views.append(contentsOf: view.subviews)
        }
        return best?.map
    }

    /// Where the picture goes: over the map, as big.
    struct Host: UIViewRepresentable {
        let fader: MapFader

        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            view.isUserInteractionEnabled = false
            fader.host = view
            return view
        }

        func updateUIView(_ view: UIView, context: Context) { fader.host = view }
    }
}

/// A stop inside the circle as riders name it (both sides of the street, often), with the ways its
/// lines go from there.
struct CircleStop: Identifiable, Equatable {
    let name: String
    /// The stops by that name.
    let codes: Set<String>
    let ways: [CircleWay]
    var id: String { name }
}

/// One line going one way from a stop in the circle.
struct CircleWay: Identifiable, Equatable {
    let line: MapLine
    let direction: Direction
    let stop: String
    let stopName: String
    let coordinate: CLLocationCoordinate2D
    var id: String { "\(line.id)|\(direction.id)|\(stop)" }

    static func == (a: CircleWay, b: CircleWay) -> Bool { a.id == b.id }
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
        case .boston:
            MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 42.35, longitude: -71.08),
                               span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2))
        case .chicago:
            MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 41.88, longitude: -87.67),
                               span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.3))
        case .dc:
            MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 38.9, longitude: -77.03),
                               span: MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.25))
        case .la:
            MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 34.05, longitude: -118.3),
                               span: MKCoordinateSpan(latitudeDelta: 0.45, longitudeDelta: 0.45))
        }
    }

    /// How far the maps let you go: out to the whole of the city's transit network (every line it has,
    /// to the ends of the regional trains and ferries), not to the rest of the country.
    var cameraBounds: MapCameraBounds {
        let network = network
        // As a map rect: given a region, MapKit turns it into one with latitude and longitude the wrong
        // way round on the device, logging "invalid coordinate" at every frame.
        let corner = { (lat: Double, lon: Double) in MKMapPoint(CLLocationCoordinate2D(latitude: lat, longitude: lon)) }
        let top = corner(network.center.latitude + network.span.latitudeDelta * 0.55, network.center.longitude - network.span.longitudeDelta * 0.55)
        let bottom = corner(network.center.latitude - network.span.latitudeDelta * 0.55, network.center.longitude + network.span.longitudeDelta * 0.55)
        return MapCameraBounds(
            centerCoordinateBounds: MKMapRect(x: top.x, y: top.y, width: bottom.x - top.x, height: bottom.y - top.y),
            maximumDistance: farthest)
    }

    /// How far out the maps' camera goes, in meters: enough for the whole network with a little room
    /// around it (a camera that high shows about half its distance from top to bottom;
    /// the width counts for more, as the maps are taller than wide), and never less than a little
    /// past the area they open on.
    var farthest: Double {
        let network = network
        let tall = network.span.latitudeDelta * 111_000
        let wide = network.span.longitudeDelta * 111_000 * cos(network.center.latitude * .pi / 180)
        return max(max(tall, wide * 1.6) * 2.1, region.span.latitudeDelta * 111_000 * 4.5)
    }

    /// The camera's middle, kept over the network as `cameraBounds` keeps it for a map that moves itself.
    func keepingInside(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let network = network, reach = 0.55
        return CLLocationCoordinate2D(
            latitude: min(max(coordinate.latitude, network.center.latitude - network.span.latitudeDelta * reach),
                          network.center.latitude + network.span.latitudeDelta * reach),
            longitude: min(max(coordinate.longitude, network.center.longitude - network.span.longitudeDelta * reach),
                           network.center.longitude + network.span.longitudeDelta * reach))
    }

    /// The area all of the city's lines cover, from its line map on the device: as worked out this
    /// launch, else the last, else (on the first launch) the area the maps open on. Never worked out
    /// here: the maps ask for it at every redraw, and reading New York's line map takes seconds.
    var network: MKCoordinateRegion {
        if let known = City.networkLock.withLock({ City.networks[self] }) { return known }
        City.prepareNetwork(for: [self])
        return City.savedNetwork(self) ?? region
    }

    /// Works out `cities`' networks in the background, once per launch each, and keeps them for the next.
    static func prepareNetwork(for cities: [City]) {
        let wanted = networkLock.withLock {
            let wanted = cities.filter { networks[$0] == nil && !preparing.contains($0) }
            preparing.formUnion(wanted)
            return wanted
        }
        guard !wanted.isEmpty else { return }
        Task.detached(priority: .utility) {
            for city in wanted {
                guard let found = city.measureNetwork() else {
                    // No line map yet: the opening area, asked again next time.
                    _ = networkLock.withLock { preparing.remove(city) }
                    continue
                }
                networkLock.withLock { networks[city] = found }
                UserDefaults.standard.set([found.center.latitude, found.center.longitude, found.span.latitudeDelta, found.span.longitudeDelta],
                                          forKey: "network-\(city.rawValue)")
            }
        }
    }

    private static func savedNetwork(_ city: City) -> MKCoordinateRegion? {
        guard let saved = UserDefaults.standard.array(forKey: "network-\(city.rawValue)") as? [Double], saved.count == 4 else { return nil }
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: saved[0], longitude: saved[1]),
                                  span: MKCoordinateSpan(latitudeDelta: saved[2], longitudeDelta: saved[3]))
    }

    private func measureNetwork() -> MKCoordinateRegion? {
        var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
        for line in TransitService.cachedLineMap(in: self) {
            for shape in line.shapes {
                for point in shape where point.count == 2 {
                    minLat = min(minLat, point[0]); maxLat = max(maxLat, point[0])
                    minLon = min(minLon, point[1]); maxLon = max(maxLon, point[1])
                }
            }
        }
        guard minLat < maxLat, minLon < maxLon else { return nil }
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
                                  span: MKCoordinateSpan(latitudeDelta: max(maxLat - minLat, region.span.latitudeDelta),
                                                         longitudeDelta: max(maxLon - minLon, region.span.longitudeDelta)))
    }

    nonisolated(unsafe) private static var networks: [City: MKCoordinateRegion] = [:]
    nonisolated(unsafe) private static var preparing: Set<City> = []
    private static let networkLock = NSLock()
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
struct LineLayer: MapContent, Equatable {
    let lines: [MapLine]
    /// Each line's pieces, the same ones every time (see `HomeMap.Prepared`).
    let polylines: [String: [MKPolyline]]
    /// The ferries' dashes: the longer ones (`farPolylines`) when `farFerries`, and only those within
    /// `ferryArea` if there is one. The pieces are always the same ones, so MapKit keeps those it has.
    let farPolylines: [String: [MKPolyline]]
    let ferryArea: MKMapRect?
    let farFerries: Bool
    let pathsVersion: Int
    let selectedID: String?
    let alsoLineIDs: Set<String>
    let candidateIDs: Set<String>
    /// The lines stopping inside the circle, while it's out: up front, the rest stepping back.
    let circleLineIDs: Set<String>
    let colorScheme: ColorScheme
    let isBackground: (MapLine) -> Bool

    static func == (a: Self, b: Self) -> Bool {
        a.pathsVersion == b.pathsVersion && a.farFerries == b.farFerries && same(a.ferryArea, b.ferryArea)
            && a.selectedID == b.selectedID && a.alsoLineIDs == b.alsoLineIDs
            && a.candidateIDs == b.candidateIDs && a.circleLineIDs == b.circleLineIDs && a.colorScheme == b.colorScheme && a.lines.map(\.id) == b.lines.map(\.id)
    }

    var body: some MapContent {
        ForEach(lines) { line in
            let isSelected = line.id == selectedID || alsoLineIDs.contains(line.id)
            let isCandidate = !isSelected && candidateIDs.contains(line.id)
            let isCircled = circleLineIDs.contains(line.id)
            let isStepBack = selectedID == nil && !circleLineIDs.isEmpty && !isCircled
            // Many lines share a color (all Muni buses are blue), so only the selected line
            // keeps full strength; nearby ones stay a bit clearer than the rest.
            // New York's buses are a fine, faint web under the trains until one is picked.
            let background = isBackground(line) && !isSelected
            let width: CGFloat = isSelected ? 7 : isCircled ? 5 : isCandidate ? 3.5 : background ? 1.5 : 3
            // Ferries dashed across the water. Not with the stroke's dash: MapKit draws those blurred and
            // about three times too wide. As short pieces of line instead, a few hundred meters each.
            ForEach(pieces(of: line), id: \.self) { polyline in
                MapPolyline(polyline)
                    .stroke(line.mapColor.legible(on: colorScheme)
                                .opacity((isStepBack ? 0.22 : selectedID == nil || isSelected ? 1 : isCandidate ? 0.5 : 0.22)
                                         * (background && !isCandidate && !isCircled ? 0.45 : 1)),
                            style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }
        }
    }

    static func same(_ a: MKMapRect?, _ b: MKMapRect?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): MKMapRectEqualToRect(a, b)
        default: false
        }
    }

    private func pieces(of line: MapLine) -> [MKPolyline] {
        guard line.mode == "ferry" else { return polylines[line.id] ?? [] }
        let dashes = (farFerries ? farPolylines : polylines)[line.id] ?? []
        guard let ferryArea else { return dashes }
        return dashes.filter { $0.boundingMapRect.intersects(ferryArea) }
    }

    /// `path` cut into dashes: `on` meters of it, then a gap of `off`.
    nonisolated static func dashed(_ path: [CLLocationCoordinate2D], on: Double = 300, off: Double = 220) -> [[CLLocationCoordinate2D]] {
        var dashes: [[CLLocationCoordinate2D]] = []
        var current: [CLLocationCoordinate2D] = []
        var drawing = true
        var left = on
        for (a, b) in zip(path, path.dropFirst()) {
            let length = meters(a, b)
            guard length > 0 else { continue }
            var at = 0.0
            if drawing, current.isEmpty { current = [a] }
            while length - at > left {
                at += left
                let t = at / length
                let point = CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                                   longitude: a.longitude + (b.longitude - a.longitude) * t)
                if drawing {
                    current.append(point)
                    dashes.append(current)
                    current = []
                } else {
                    current = [point]
                }
                drawing.toggle()
                left = drawing ? on : off
            }
            left -= length - at
            if drawing { current.append(b) }
        }
        if current.count > 1 { dashes.append(current) }
        return dashes
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
        if id.hasPrefix("SL"), id.count <= 3 { return 0 }                         // Boston's Silver Line
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

/// The picker's stop dots over the map rather than on it, as the buses are: every stop around (those
/// in the circle marked), and over them the selected line's own. On the map, each change (and they
/// change as it zooms, and as the circle moves) has MapKit build every line on it again, half a second
/// in New York. Drawn where the map shows them on every frame, so they stay put on it.
struct StopDotsLayer: View {
    let stops: [MapStop]
    let inside: Set<String>
    /// The selected line's stops, shown closer in than `lineDotsBelow` meters per point.
    let lineDots: [CLLocationCoordinate2D]
    let lineDotsBelow: Double
    let lineColor: Color
    let proxy: MapProxy
    /// What the map shows as it moves: read, so the dots are drawn again as it does.
    let motion: MapMotion
    let mapSize: CGSize

    /// Where the map shows `coordinate`: as MapKit says, or while it can't (in the middle of a pinch),
    /// worked out from the area it shows, as for the buses.
    private func place(_ coordinate: CLLocationCoordinate2D, in shown: MKMapRect?) -> CGPoint? {
        if let spot = proxy.convert(coordinate, to: .local) { return spot }
        guard let shown, shown.width > 0, shown.height > 0 else { return nil }
        let spot = MKMapPoint(coordinate)
        return CGPoint(x: (spot.x - shown.minX) / shown.width * mapSize.width,
                       y: (spot.y - shown.minY) / shown.height * mapSize.height)
    }

    var body: some View {
        // Placed here rather than in the drawing, reading where the map is: so they're placed again, and
        // drawn again, as it moves.
        let shown = motion.shown
        let dots = stops.compactMap { stop in
            place(stop.coordinate, in: shown).map { (spot: $0, inside: inside.contains(stop.code)) }
        }
        let zoom = shown.map { $0.width * MKMetersPerMapPointAtLatitude($0.origin.coordinate.latitude) / max(mapSize.width, 1) } ?? .infinity
        let line = zoom < lineDotsBelow ? lineDots.compactMap { place($0, in: shown) } : []
        Canvas { context, _ in
            for dot in dots {
                self.dot(at: dot.spot, size: dot.inside ? 10 : 8, stroke: dot.inside ? .primary : .gray, width: dot.inside ? 2 : 1.5, in: context)
            }
            for spot in line {
                self.dot(at: spot, size: 9, stroke: lineColor, width: 2, in: context)
            }
        }
        .allowsHitTesting(false)
    }

    private func dot(at spot: CGPoint, size: CGFloat, stroke: Color, width: CGFloat, in context: GraphicsContext) {
        let circle = Path(ellipseIn: CGRect(x: spot.x - size / 2, y: spot.y - size / 2, width: size, height: size))
        context.fill(circle, with: .color(.white))
        context.stroke(circle, with: .color(stroke), lineWidth: width)
    }
}

/// The line name badges over the map rather than on it, as the stop dots are: on it, each time they
/// were placed again MapKit went over the whole map, longer than a frame. Here they go along with the
/// map on every frame, where it shows their spot, and are only placed again (`HomeMap.relabel`) as it rests.
struct LineBadgesLayer: View {
    struct Badge: Identifiable, Equatable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let leaving: Bool
        let text: String
        let color: Color
        let textColor: Color
        let round: Bool
        let spoken: String

        static func == (a: Badge, b: Badge) -> Bool {
            a.id == b.id && a.leaving == b.leaving && a.text == b.text && a.color == b.color && a.round == b.round
                && a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
        }
    }

    let badges: [Badge]
    /// A line picked: they step back, as the other lines do.
    let stepBack: Bool
    let proxy: MapProxy
    /// What the map shows as it moves: read, so they're placed again as it does.
    let motion: MapMotion
    let mapSize: CGSize

    var body: some View {
        let shown = motion.shown
        ZStack(alignment: .topLeading) {
            ForEach(badges) { badge in
                if let spot = place(badge.coordinate, in: shown) {
                    BadgeMark(badge: badge).position(spot)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(stepBack ? 0.35 : 1)
        .allowsHitTesting(false)
        // Along with the map, which MapKit moves its own way: not with anything else animating.
        .transaction { $0.animation = nil }
    }

    /// Where the map shows `coordinate`: as MapKit says, or while it can't (in the middle of a pinch),
    /// worked out from the area it shows.
    private func place(_ coordinate: CLLocationCoordinate2D, in shown: MKMapRect?) -> CGPoint? {
        if let spot = proxy.convert(coordinate, to: .local) { return spot }
        guard let shown, shown.width > 0, shown.height > 0 else { return nil }
        let spot = MKMapPoint(coordinate)
        return CGPoint(x: (spot.x - shown.minX) / shown.width * mapSize.width,
                       y: (spot.y - shown.minY) / shown.height * mapSize.height)
    }

    /// One badge, the same view while only where it is changes, so it isn't made again on every frame.
    private struct BadgeMark: View, Equatable {
        let badge: Badge

        var body: some View {
            FadingBadge(leaving: badge.leaving) {
                LineBadge(line: badge.text, font: .system(size: 12, weight: .heavy, design: .rounded),
                          color: badge.color, textColor: badge.textColor, round: badge.round, spoken: badge.spoken)
                    .fixedSize()
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
            }
        }
    }
}

/// A stop dot on the map, identified by where it is.
struct StopDot: Hashable {
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

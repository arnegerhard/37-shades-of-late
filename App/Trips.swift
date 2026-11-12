import MapKit
import SwiftUI

// Trips: a commute between home and work, each way there one or more ways you take (a walk to a stop, a
// line, or lines from the same platform, to another stop, a walk on). The page works out each way live
// (the wait, the ride, the walks) and says which to take now: the one that gets you there soonest as it
// feels, its walks weighed by the hills on them (see `Walk`), with the real times shown beside it.

/// Home or work: an address, or a spot picked on the map.
struct TripPlace: Codable, Hashable {
    var name: String
    var lat: Double
    var lon: Double

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

/// One way to get there: a walk to a stop, a line from there, off at another stop, then a walk.
struct TripWay: Codable, Hashable, Identifiable {
    var id = UUID().uuidString
    /// The line, its direction and the stop to get on at.
    var board: Selection
    var alightCode: String
    var alightName: String
    /// To the stop, and from the stop you get off at, on the flat; and how far up (down, below zero), in
    /// meters, where the heights are known.
    var walkBeforeMinutes = 0
    var walkMinutes = 0
    var climbBefore: Double?
    var climbAfter: Double?
    /// Where each of the board's other lines (`board.also`) is got off, by line.
    var alsoAlight: [String: String]?
    /// A second ride, after a walk (or none) from where the first gets off; `alight…` and `walkMinutes` are then the second's.
    var next: TripLeg?

    /// Minutes more (or less) it feels than the clock says, for its hills (see `Walk`).
    var feltExtraMinutes: Double {
        Walk.extraMinutes(flat: walkBeforeMinutes, climb: climbBefore) + Walk.extraMinutes(flat: walkMinutes, climb: climbAfter)
            + (next.map { Walk.extraMinutes(flat: $0.changeMinutes, climb: $0.changeClimb) } ?? 0)
    }

    /// Where the first ride ends: the stop got off at, or with a second ride, where you change.
    var firstAlightCode: String { next?.fromCode ?? alightCode }
    var firstAlightName: String { next?.fromName ?? alightName }

    /// The first ride's lines and direction, at the stops to get off at: their times there.
    var alight: Selection {
        let code = firstAlightCode
        return Selection(lineID: board.lineID, lineName: board.lineName, directionID: board.directionID, destination: board.destination,
                         stopCode: code, stopName: firstAlightName, city: board.city,
                         also: board.also.map { Selection.OtherLine(lineID: $0.lineID, directionID: $0.directionID, stopCode: alsoAlight?[$0.lineID] ?? code) })
    }
}

/// A way's second ride: got off the first at `from…`, a walk to `board` (none, if it's the same stop), and on.
struct TripLeg: Codable, Hashable {
    var fromCode: String
    var fromName: String
    var changeMinutes: Int
    var changeClimb: Double?
    var board: Selection
    /// Where each of its lines is got off: its main line's is the way's `alightCode`.
    var alsoAlight: [String: String]?

    func alight(_ code: String, _ name: String) -> Selection {
        Selection(lineID: board.lineID, lineName: board.lineName, directionID: board.directionID, destination: board.destination,
                  stopCode: code, stopName: name, city: board.city,
                  also: board.also.map { Selection.OtherLine(lineID: $0.lineID, directionID: $0.directionID, stopCode: alsoAlight?[$0.lineID] ?? code) })
    }
}

/// How a walk feels: its time on the flat, plus every meter climbed (much worse), less some for every meter
/// gone down (easier, and fun, up to a point).
enum Walk {
    /// Seconds a meter up adds, and a meter down takes off; going down saves at most this share of the walk.
    static let upSeconds = 10.0
    static let downSeconds = 2.0
    static let mostDownShare = 0.3

    static func extraMinutes(flat: Int, climb: Double?) -> Double {
        guard let climb else { return 0 }
        return max(climb, 0) * upSeconds / 60 - min(max(-climb, 0) * downSeconds / 60, Double(flat) * mostDownShare)
    }

    /// "8 min ↓45 m", "4 min ↑12 m", "3 min".
    static func describe(_ minutes: Int, climb: Double?) -> String {
        guard let climb, abs(climb) >= 5 else { return "\(minutes) min" }
        return "\(minutes) min \(climb > 0 ? "↑" : "↓")\(Int(abs(climb).rounded())) m"
    }
}

/// A commute: the ways home, and the ways to work.
struct Trip: Codable, Hashable, Identifiable {
    /// Trips are paused: off, the app shows no trip pages, circles or "Add a trip", and leaves saved trips
    /// alone. The proxy's /v1/trip stays up.
    static let enabled = false

    var id = UUID().uuidString
    var city: City
    var home: TripPlace?
    var work: TripPlace?
    var toHome: [TripWay] = []
    var toWork: [TripWay] = []

    func ways(home: Bool) -> [TripWay] { home ? toHome : toWork }

    /// Kept in the App Group, beside the favorites.
    static var all: [Trip] {
        get {
            guard let data = AppGroup.defaults.data(forKey: "trips"), let trips = try? JSONDecoder().decode([Trip].self, from: data) else { return [] }
            return trips
        }
        set { AppGroup.defaults.set(try? JSONEncoder().encode(newValue), forKey: "trips") }
    }

    /// Which way the page opens on: to work in the morning, home from the afternoon on.
    static var homeByDefault: Bool { Calendar.current.component(.hour, from: .now) >= 13 }
}

/// A way, worked out now: the next bus or train you'd catch, and when you'd be there.
struct TripRide: Hashable {
    let way: TripWay
    /// The one you'd catch, at the stop you get on at.
    let leaves: Departure?
    /// At the stop you get off at, and there after the walk; nil where the feeds don't reach that far.
    let arrives: Date?
    var there: Date? { arrives.map { $0.addingTimeInterval(Double(way.walkMinutes) * 60) } }
    /// When it feels like you'd be there: its walks weighed by their hills.
    var feelsThere: Date? { there.map { $0.addingTimeInterval(way.feltExtraMinutes * 60) } }

    /// The ride: the first one leaving that the times at the stop to get off at have arriving after it.
    /// (The same line, the same way: the bus that leaves first gets there first.)
    static func work(_ way: TripWay, now: Date = .now) async -> TripRide {
        async let leaving = TransitService.departures(for: way.board, client: .app)
        async let arriving = TransitService.departures(for: way.alight, client: .app)
        // Only those you can still walk to.
        let departures = ((try? await leaving) ?? []).filter { $0.time > now.addingTimeInterval(Double(way.walkBeforeMinutes) * 60 - 30) }
        let arrivals = (try? await arriving) ?? []
        var first: (leaves: Departure, arrives: Date)?
        for departure in departures.prefix(3) {
            if let arrival = arrivals.first(where: { $0.time > departure.time.addingTimeInterval(60) && ($0.line == nil || $0.line == departure.line) }) {
                first = (departure, arrival.time)
                break
            }
        }
        guard let first else { return TripRide(way: way, leaves: departures.first, arrives: nil) }
        guard let next = way.next else { return TripRide(way: way, leaves: first.leaves, arrives: first.arrives) }
        // The second ride: the first one you can make after the walk to it, and when it gets there.
        let ready = first.arrives.addingTimeInterval(Double(next.changeMinutes) * 60 + 30)
        async let changing = TransitService.departures(for: next.board, client: .app)
        async let ending = TransitService.departures(for: next.alight(way.alightCode, way.alightName), client: .app)
        let seconds = ((try? await changing) ?? []).filter { $0.time >= ready }
        let ends = (try? await ending) ?? []
        for departure in seconds.prefix(3) {
            if let arrival = ends.first(where: { $0.time > departure.time.addingTimeInterval(60) && ($0.line == nil || $0.line == departure.line) }) {
                return TripRide(way: way, leaves: first.leaves, arrives: arrival.time)
            }
        }
        return TripRide(way: way, leaves: first.leaves, arrives: nil)
    }
}

/// A trip as a page: its way to take now on the map, with the bus on it, and over the bottom, the pick,
/// why, and each way's times; a switch between home and work, and the pencil to change the ways.
struct TripPage: View {
    let trip: Trip
    let topInset: CGFloat
    let bottomInset: CGFloat
    let leadingInset: CGFloat
    let onEdit: () -> Void

    @State private var home = Trip.homeByDefault
    @State private var rides: [TripRide] = []
    /// A way tapped, on the map instead of the pick.
    @State private var shownWay: String?
    @State private var feed = DepartureFeed()
    @State private var gesture: MapGesture?

    private var ways: [TripWay] { trip.ways(home: home) }
    private var best: TripRide? {
        rides.filter { $0.feelsThere != nil }.min { $0.feelsThere! < $1.feelsThere! } ?? rides.first
    }
    private var onMap: TripWay? { ways.first { $0.id == shownWay } ?? best?.way ?? ways.first }

    var body: some View {
        Group {
            if let way = onMap {
                HomeMap(city: trip.city, open: way.board, feed: feed, topInset: topInset, bottomInset: Self.captionRoom + bottomInset,
                        leadingInset: leadingInset, gesture: gesture)
                    .overlay { MapTouches(onGesture: { gesture = $0 }) }
                    .task(id: way.board) { await feed.follow(way.board) }
            } else {
                Color(white: 0.12)
            }
        }
        .overlay(alignment: .bottom) { caption }
        // Each way worked out again every half minute, and as soon as the direction changes.
        .task(id: "\(home)|\(ways.map(\.id))") {
            while !Task.isCancelled {
                let worked = await withTaskGroup(of: TripRide.self) { group in
                    for way in ways { group.addTask { await TripRide.work(way) } }
                    var all: [TripRide] = []
                    for await ride in group { all.append(ride) }
                    return all
                }
                withAnimation(.smooth(duration: 0.3)) { rides = ways.compactMap { way in worked.first { $0.way.id == way.id } } }
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .onChange(of: home) { shownWay = nil; rides = [] }
    }

    static let captionRoom: CGFloat = 190

    private var caption: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                direction
                Spacer()
                Button(action: onEdit) {
                    Image(systemName: "pencil").font(.system(size: 20, weight: .medium)).frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Change the ways")
            }
            if ways.isEmpty {
                Text(home ? "No way home yet. Tap the pencil to add one." : "No way to work yet. Tap the pencil to add one.")
                    .font(.subheadline)
            } else {
                TimelineView(.everyMinute) { context in
                    VStack(alignment: .leading, spacing: 6) {
                        headline(at: context.date)
                        ForEach(rides, id: \.way.id) { ride in row(ride, at: context.date) }
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
        .padding(.horizontal, 14)
        .padding(.top, 40)
        .padding(.bottom, bottomInset + 34)
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.5), .black.opacity(0.78)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        }
    }

    /// Home or work: where this trip goes now.
    private var direction: some View {
        HStack(spacing: 0) {
            ForEach([true, false], id: \.self) { toHome in
                Button {
                    Journey.shared.tap("trip.direction", toHome ? "home" : "work")
                    withAnimation(.snappy(duration: 0.2)) { home = toHome }
                } label: {
                    Label(toHome ? "Home" : "Work", systemImage: toHome ? "house.fill" : "building.2.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(home == toHome ? Color.white.opacity(0.25) : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(home == toHome ? .isSelected : [])
            }
        }
        .padding(3)
        .background(.black.opacity(0.45), in: Capsule())
    }

    @ViewBuilder private func headline(at now: Date) -> some View {
        if let best, let there = best.there {
            let others = rides.filter { $0.way.id != best.way.id && $0.there != nil }
            // The one that's sooner but feels worse, if there is one: why not that.
            let sooner = others.first { $0.there! < there }
            VStack(alignment: .leading, spacing: 2) {
                Text("Take the \(best.way.lineSummary) · \(home ? "home" : "work") \(there.formatted(date: .omitted, time: .shortened))")
                    .font(.title3.weight(.bold))
                if let sooner, let soonerThere = sooner.there {
                    let minutes = Int(there.timeIntervalSince(soonerThere) / 60)
                    let climb = max(sooner.way.climbBefore ?? 0, sooner.way.climbAfter ?? 0)
                    Text("The \(sooner.way.lineSummary) is \(minutes) min faster. \(climb >= 10 ? "The hill isn't." : "The walk isn't.")")
                        .font(.footnote).italic().opacity(0.85)
                } else if let leaves = best.leaves {
                    Text(Quip.forWait(until: leaves.time, from: now, line: best.way.board.lineLabel))
                        .font(.footnote).italic().opacity(0.85)
                }
            }
        } else {
            Text(rides.isEmpty ? "Working it out…" : "No times to go by just now.").font(.title3.weight(.bold))
        }
    }

    private func row(_ ride: TripRide, at now: Date) -> some View {
        let isBest = ride.way.id == best?.way.id
        // When to set off: the bus's time less the walk to it.
        let wait = ride.leaves.map { max(0, Int($0.time.timeIntervalSince(now) / 60) - ride.way.walkBeforeMinutes) }
        return Button {
            withAnimation(.smooth(duration: 0.3)) { shownWay = shownWay == ride.way.id ? nil : ride.way.id }
        } label: {
            HStack(spacing: 8) {
                WayBadges(way: ride.way)
                VStack(alignment: .leading, spacing: 1) {
                    Text(wait.map { $0 == 0 ? "go now · \(ride.way.alightName)" : "go in \($0) · \(ride.way.alightName)" } ?? "no times · \(ride.way.alightName)")
                        .font(.subheadline).lineLimit(1)
                    if ride.way.walkBeforeMinutes + ride.way.walkMinutes > 0 {
                        Label(ride.way.walkSummary, systemImage: "figure.walk")
                            .font(.caption)
                            .opacity(0.85)
                    }
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(ride.there.map { $0.formatted(date: .omitted, time: .shortened) } ?? "–")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(isBest ? .green : .white)
                    if abs(ride.way.feltExtraMinutes) >= 1, let feels = ride.feelsThere {
                        Text("feels \(feels.formatted(date: .omitted, time: .shortened))").font(.caption2).opacity(0.7)
                    }
                }
                .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isBest ? Color.white.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A trip's circle down the side: a house or an office, for where it goes.
struct TripStory: View {
    let home: Bool

    var body: some View {
        Image(systemName: home ? "house.fill" : "building.2.fill")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black.opacity(0.7), in: Circle())
            .padding(3)
            .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1.5))
    }
}

/// Setting up a trip: home and work, by address or on the map; then for each direction its ways, from
/// those the app finds between the two (lines with a stop a short walk from each, in the right order) or
/// from your own stops, each with what makes it worse, in minutes.
struct TripEditor: View {
    @State var trip: Trip
    /// The stops a way can start from by hand: the city's favorites.
    let stops: [Selection]
    let onSave: (Trip) -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var home = Trip.homeByDefault
    @State private var adding = false
    @State private var picking: PlaceKind?
    @State private var suggestions: [TripWay]?

    enum PlaceKind: String, Identifiable { case home, work; var id: String { rawValue } }

    private var ways: Binding<[TripWay]> { home ? $trip.toHome : $trip.toWork }
    /// Where this direction starts and ends.
    private var ends: (from: TripPlace, to: TripPlace)? {
        guard let h = trip.home, let w = trip.work else { return nil }
        return home ? (w, h) : (h, w)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    placeRow(.home, trip.home)
                    placeRow(.work, trip.work)
                } footer: {
                    Text("Search an address, or pick the spot on the map.")
                }
                if ends != nil {
                    Picker("Going", selection: $home) {
                        Label("Home", systemImage: "house.fill").tag(true)
                        Label("To work", systemImage: "building.2.fill").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    Section {
                        ForEach(ways) { $way in wayRows($way) }
                            .onDelete { ways.wrappedValue.remove(atOffsets: $0) }
                        if ways.wrappedValue.isEmpty {
                            Text("Add the ways you take below.").foregroundStyle(.secondary)
                        }
                    } header: {
                        Text(home ? "Your ways home" : "Your ways to work")
                    } footer: {
                        Text("The trip page picks the one that gets you there soonest as it feels: a walk uphill counts for more, one downhill for a little less.")
                    }
                    Section("Lines between them") {
                        if let suggestions {
                            let new = suggestions.filter { s in !ways.wrappedValue.contains { $0.board.lineID == s.board.lineID && $0.board.stopCode == s.board.stopCode && $0.next?.board.lineID == s.next?.board.lineID } }
                            ForEach(new) { way in suggestionRow(way) }
                            if new.isEmpty {
                                Text(suggestions.isEmpty ? "No line goes from near one to near the other. Add a way from your stops." : "All added.")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            HStack { ProgressView(); Text("Looking for lines…").foregroundStyle(.secondary) }
                        }
                        Button { adding = true } label: { Label("Add a way from your stops", systemImage: "plus") }
                    }
                }
                Section {
                    Button("Delete this trip", role: .destructive) { onDelete(); dismiss() }
                }
            }
            .navigationTitle("Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { onSave(trip); dismiss() }.bold() }
            }
            .sheet(isPresented: $adding) {
                WayPicker(stops: stops) { ways.wrappedValue.append($0) }
            }
            .sheet(item: $picking) { kind in
                PlacePicker(city: trip.city, title: kind == .home ? "Home" : "Work",
                            start: kind == .home ? trip.home : trip.work) { place in
                    if kind == .home { trip.home = place } else { trip.work = place }
                }
            }
            .task(id: "\(home)|\(trip.home?.lat ?? 0)|\(trip.work?.lat ?? 0)") {
                suggestions = nil
                guard let ends else { return }
                let found = await TripPlanner.ways(from: ends.from.coordinate, to: ends.to.coordinate, in: trip.city)
                // Not if the direction (or a place) changed while it looked.
                if !Task.isCancelled { suggestions = found }
            }
        }
    }

    private func placeRow(_ kind: PlaceKind, _ place: TripPlace?) -> some View {
        Button { picking = kind } label: {
            HStack(spacing: 12) {
                Image(systemName: kind == .home ? "house.fill" : "building.2.fill")
                    .foregroundStyle(LineBadge.red)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind == .home ? "Home" : "Work").font(.caption).foregroundStyle(.secondary)
                    Text(place?.name ?? "Set where").foregroundStyle(place == nil ? Color.accentColor : .primary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func suggestionRow(_ way: TripWay) -> some View {
        Button {
            withAnimation { ways.wrappedValue.append(way) }
        } label: {
            HStack(spacing: 10) {
                WayBadges(way: way)
                VStack(alignment: .leading, spacing: 1) {
                    Text(way.stopsSummary).font(.subheadline).lineLimit(2)
                    Text(way.walkSummary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(LineBadge.red)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add the \(way.board.lineLabel) from \(way.board.stopName)")
    }

    @ViewBuilder private func wayRows(_ way: Binding<TripWay>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                WayBadges(way: way.wrappedValue)
                Text(way.wrappedValue.stopsSummary).font(.subheadline)
            }
            if way.wrappedValue.climbBefore != nil || way.wrappedValue.climbAfter != nil {
                // Worked out from the map and the hills.
                Label(way.wrappedValue.walkSummary, systemImage: "figure.walk")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                // Added from your stops: the walks as you know them.
                Stepper("Walk to it: \(way.wrappedValue.walkBeforeMinutes) min", value: way.walkBeforeMinutes, in: 0...30)
                    .font(.subheadline)
                Stepper("Walk after: \(way.wrappedValue.walkMinutes) min", value: way.walkMinutes, in: 0...30)
                    .font(.subheadline)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The ways between two places: a small graph of every stop within a walk of each (the walks to them weighed
/// by their hills, from the proxy's heights), and the lines between, ridden along their stops. For each line
/// and direction, the stops that make it quickest as it feels; then lines from the same platform to the same
/// place made one way ("J K L M N at Church"), the quickest first.
enum TripPlanner {
    /// As far as anyone walks to a stop in a straight line (about 15 minutes on the streets), the streets'
    /// share more than a straight line, and walking pace.
    static let reach = 1_300.0
    static let streets = 1.25
    static let metersPerMinute = 80.0
    /// Riding pace, by kind, in meters a minute (stops and lights in), and a wait to count for every line.
    static let busPace = 220.0
    static let railPace = 420.0
    static let wait = 5.0

    private struct Near {
        let stop: MapStop
        let flat: Int
        let climb: Double?
        let felt: Double
    }

    private struct Found {
        let line: String
        let name: String
        let direction: Direction
        let board: Stop
        let alight: Stop
        let start: Near
        let end: Near
        let cost: Double
    }

    static func ways(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, in city: City) async -> [TripWay] {
        // The proxy's search, where it has the city's network: quicker, and with a change of line.
        if let found = await TransitService.tripWays(from: (from.latitude, from.longitude), to: (to.latitude, to.longitude), in: city) {
            return found.map { way(from: $0, in: city) }
        }
        var stops = TransitService.cachedStops(in: city)
        if stops.isEmpty { stops = await TransitService.refreshedStops(in: city) ?? [] }
        let close = { (place: CLLocationCoordinate2D) in
            Array(stops.map { ($0, meters($0.coordinate, place)) }.filter { $0.1 <= reach }.sorted { $0.1 < $1.1 }.prefix(200))
        }
        let atStart = close(from), atEnd = close(to)
        guard !atStart.isEmpty, !atEnd.isEmpty else { return [] }

        // Every height at once: the two places, then the stops.
        let points = [from, to] + atStart.map(\.0.coordinate) + atEnd.map(\.0.coordinate)
        let heights = await TransitService.elevations(of: points.map { ($0.latitude, $0.longitude) })
        let height = { (i: Int) in heights.indices.contains(i) ? heights[i] : nil }
        let near = { (list: [(MapStop, Double)], offset: Int, place: Double?, leaving: Bool) -> [String: Near] in
            var found = [String: Near]()
            for (i, (stop, straight)) in list.enumerated() {
                let flat = max(1, Int((straight * streets / metersPerMinute).rounded()))
                let there = height(offset + i)
                // Leaving, from the place to the stop; arriving, from the stop to the place.
                let climb: Double? = place.flatMap { p in there.map { leaving ? $0 - p : p - $0 } }
                let felt = Double(flat) + Walk.extraMinutes(flat: flat, climb: climb)
                if let kept = found[stop.code], kept.felt <= felt { continue }
                found[stop.code] = Near(stop: stop, flat: flat, climb: climb, felt: felt)
            }
            return found
        }
        let starts = near(atStart, 2, height(0), true)
        let ends = near(atEnd, 2 + atStart.count, height(1), false)

        // Which lines stop at each: with the stops where known, else asked (Muni's), forty at a time.
        var linesAt = [String: Set<String>]()
        for stop in atStart.map(\.0) + atEnd.map(\.0) { if let lines = stop.lines { linesAt[stop.code] = Set(lines) } }
        let asking = Array(Set((atStart + atEnd).map(\.0.code).filter { linesAt[$0] == nil }))
        for start in stride(from: 0, to: asking.count, by: 40) {
            let chunk = Array(asking[start..<min(start + 40, asking.count)])
            for line in (try? await TransitService.linesAtStops(chunk, in: city)) ?? [] {
                linesAt[line.stop ?? chunk[0], default: []].insert(line.line)
            }
        }
        // Lines at both ends, the ones with the least walking first.
        var bestStart = [String: Double](), bestEnd = [String: Double]()
        for (code, n) in starts { for line in linesAt[code] ?? [] { bestStart[line] = min(bestStart[line] ?? .infinity, n.felt) } }
        for (code, n) in ends { for line in linesAt[code] ?? [] { bestEnd[line] = min(bestEnd[line] ?? .infinity, n.felt) } }
        let candidates = Set(bestStart.keys).intersection(bestEnd.keys)
            .sorted { bestStart[$0]! + bestEnd[$0]! < bestStart[$1]! + bestEnd[$1]! }.prefix(30)
        let known = Dictionary(TransitService.cachedLines(in: city).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var found: [Found] = []
        await withTaskGroup(of: [Found].self) { group in
            for id in candidates {
                group.addTask {
                    let line = known[id] ?? Line(id: id, name: "", mode: "bus")
                    guard let directions = try? await TransitService.directions(for: line, in: city) else { return [] }
                    let pace = line.mode == "bus" ? busPace : railPace
                    var best: [Found] = []
                    for direction in directions {
                        // How far along the line each stop is.
                        var along = [0.0]
                        for (a, b) in zip(direction.stops, direction.stops.dropFirst()) {
                            guard let p = a.coordinate, let q = b.coordinate else { along.append(along.last!); continue }
                            along.append(along.last! + meters(p, q))
                        }
                        var all: [Found] = []
                        for (i, a) in direction.stops.enumerated() {
                            guard let start = starts[a.code] else { continue }
                            for j in direction.stops.indices where j > i {
                                guard let end = ends[direction.stops[j].code] else { continue }
                                let cost = start.felt + (along[j] - along[i]) / pace + end.felt + wait
                                all.append(Found(line: id, name: line.name, direction: direction, board: a, alight: direction.stops[j],
                                                 start: start, end: end, cost: cost))
                            }
                        }
                        // The quickest, and the quickest from somewhere else (Church as well as Castro): a few
                        // per line, each got on a few blocks from the others.
                        for f in all.sorted(by: { $0.cost < $1.cost }) where best.filter({ $0.direction.id == direction.id }).count < 3 {
                            let apart = best.filter { $0.direction.id == direction.id }.allSatisfy { kept in
                                guard let a = f.board.coordinate, let b = kept.board.coordinate else { return false }
                                return meters(a, b) > 400
                            }
                            if apart { best.append(f) }
                        }
                    }
                    return best
                }
            }
            for await some in group { found += some }
        }

        // Muni's stand-ins for a line at night or early (the N's NOWL and NBUS), where the line's there too.
        let lines = Set(found.map(\.line))
        if city == .sf {
            found.removeAll { f in
                ["OWL", "BUS"].contains { f.line.hasSuffix($0) && f.line.count > $0.count && lines.contains(String(f.line.dropLast($0.count))) }
            }
        }
        // Lines from the same platform (or one just by it) to the same place: one way.
        var groups: [[Found]] = []
        for f in found.sorted(by: { $0.cost < $1.cost }) {
            guard let fb = f.board.coordinate, let fa = f.alight.coordinate else { continue }
            // Got on just there already, by a quicker way: nothing new.
            if groups.contains(where: { g in g.contains { $0.line == f.line && $0.board.coordinate.map { meters($0, fb) <= 250 } == true } }) { continue }
            if let g = groups.firstIndex(where: { g in
                guard let gb = g[0].board.coordinate, let ga = g[0].alight.coordinate else { return false }
                // Church: the J on Church St and the K, L and M under Market, a short walk apart.
                return meters(fb, gb) <= 250 && meters(fa, ga) <= 400 && !g.contains { $0.line == f.line } && g.count < 6
            }) {
                groups[g].append(f)
            } else if groups.count < 10 {
                groups.append([f])
            }
        }
        return groups.map { g in
            let main = g[0]
            let others = g.dropFirst().sorted { $0.line.localizedStandardCompare($1.line) == .orderedAscending }
            let board = Selection(lineID: main.line, lineName: main.name, directionID: main.direction.id,
                                  destination: main.direction.destination, stopCode: main.board.code, stopName: main.board.name, city: city,
                                  also: others.map { Selection.OtherLine(lineID: $0.line, directionID: $0.direction.id,
                                                                         stopCode: $0.board.code == main.board.code ? nil : $0.board.code) })
            return TripWay(board: board, alightCode: main.alight.code, alightName: main.alight.name,
                           walkBeforeMinutes: main.start.flat, walkMinutes: main.end.flat,
                           climbBefore: main.start.climb, climbAfter: main.end.climb,
                           alsoAlight: Dictionary(others.map { ($0.line, $0.alight.code) }, uniquingKeysWith: { a, _ in a }))
        }
    }

    /// A way the proxy found, as the trip keeps it.
    private static func way(from found: FoundWay, in city: City) -> TripWay {
        func selection(_ leg: FoundWay.Leg) -> Selection {
            Selection(lineID: leg.line, lineName: "", directionID: leg.direction, destination: leg.destination,
                      stopCode: leg.board.code, stopName: leg.board.name, city: city,
                      also: leg.also.map { Selection.OtherLine(lineID: $0.line, directionID: $0.direction, stopCode: $0.board.code == leg.board.code ? nil : $0.board.code) })
        }
        let first = found.legs[0], last = found.legs[found.legs.count - 1]
        var way = TripWay(board: selection(first), alightCode: last.alight.code, alightName: last.alight.name,
                          walkBeforeMinutes: found.walkBefore.minutes, walkMinutes: found.walkAfter.minutes,
                          climbBefore: found.walkBefore.climb ?? 0, climbAfter: found.walkAfter.climb ?? 0,
                          alsoAlight: Dictionary(first.also.map { ($0.line, $0.alight.code) }, uniquingKeysWith: { a, _ in a }))
        if found.legs.count > 1 {
            way.next = TripLeg(fromCode: first.alight.code, fromName: first.alight.name,
                               changeMinutes: found.change?.minutes ?? 0, changeClimb: found.change?.climb,
                               board: selection(last),
                               alsoAlight: Dictionary(last.also.map { ($0.line, $0.alight.code) }, uniquingKeysWith: { a, _ in a }))
        }
        return way
    }

    static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}

/// Picking a place: search an address (or a place's name), or tap the spot on the map.
struct PlacePicker: View {
    let city: City
    let title: String
    let start: TripPlace?
    let onPick: (TripPlace) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = PlaceSearch()
    @State private var query = ""
    @State private var picked: TripPlace?
    @State private var position: MapCameraPosition = .automatic
    @State private var searching = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !query.isEmpty {
                    List(search.results, id: \.self) { result in
                        Button {
                            Task {
                                if let place = await search.place(for: result) { choose(place, zoom: true) }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(result.title).foregroundStyle(.primary)
                                if !result.subtitle.isEmpty { Text(result.subtitle).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    .listStyle(.plain)
                } else {
                    MapReader { proxy in
                        Map(position: $position) {
                            if let picked {
                                Marker(picked.name, systemImage: title == "Home" ? "house.fill" : "building.2.fill", coordinate: picked.coordinate)
                                    .tint(LineBadge.red)
                            }
                        }
                        .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
                        .onTapGesture { point in
                            guard let coordinate = proxy.convert(point, from: .local) else { return }
                            Task { choose(await PlaceSearch.name(of: coordinate), zoom: false) }
                        }
                    }
                    .overlay(alignment: .top) {
                        Text(picked == nil ? "Tap the spot, or search above." : picked!.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.top, 10)
                    }
                }
            }
            .searchable(text: $query, isPresented: $searching, placement: .navigationBarDrawer(displayMode: .always), prompt: "Address or place")
            .onChange(of: query) { search.query = query }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") { if let picked { onPick(picked); dismiss() } }.bold().disabled(picked == nil)
                }
            }
            .onAppear {
                search.region = city.region
                picked = start
                position = start.map { .region(MKCoordinateRegion(center: $0.coordinate, latitudinalMeters: 1500, longitudinalMeters: 1500)) }
                    ?? .region(city.region)
            }
        }
    }

    private func choose(_ place: TripPlace, zoom: Bool) {
        picked = place
        query = ""
        // Out of the search, to see it on the map with Use above.
        searching = false
        if zoom {
            withAnimation { position = .region(MKCoordinateRegion(center: place.coordinate, latitudinalMeters: 1500, longitudinalMeters: 1500)) }
        }
    }
}

/// Address suggestions as you type, around the city, and the place each stands for.
@Observable
final class PlaceSearch: NSObject, MKLocalSearchCompleterDelegate {
    var results: [MKLocalSearchCompletion] = []
    var query = "" { didSet { completer.queryFragment = query } }
    var region: MKCoordinateRegion? { didSet { if let region { completer.region = region } } }
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        // Only places in the city (an address there, not the same street name in another state).
        if #available(iOS 18.0, *) { completer.regionPriority = .required }
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) { results = completer.results }
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) { results = [] }

    func place(for completion: MKLocalSearchCompletion) async -> TripPlace? {
        guard let item = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start().mapItems.first else { return nil }
        let coordinate = item.placemark.coordinate
        return TripPlace(name: completion.title, lat: coordinate.latitude, lon: coordinate.longitude)
    }

    /// A tapped spot's street address, or where it is if there's none.
    static func name(of coordinate: CLLocationCoordinate2D) async -> TripPlace {
        let mark = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)).first
        let street = [mark?.subThoroughfare, mark?.thoroughfare].compactMap { $0 }.joined(separator: " ")
        return TripPlace(name: street.isEmpty ? (mark?.name ?? "Picked on the map") : street, lat: coordinate.latitude, lon: coordinate.longitude)
    }
}

/// A new way: one of your stops (its line and direction), then where you get off, from that line's stops after it.
private struct WayPicker: View {
    let stops: [Selection]
    let onPick: (TripWay) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(stops) { stop in
                NavigationLink {
                    AlightPicker(board: stop) { onPick($0); dismiss() }
                } label: {
                    HStack(spacing: 8) {
                        LineBadges(parts: stop.badgeParts, font: .system(.subheadline, design: .rounded).weight(.heavy), round: stop.roundBadge)
                            .fixedSize()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(stop.stopName).font(.subheadline)
                            Text("To \(stop.destination)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .overlay {
                if stops.isEmpty {
                    ContentUnavailableView("No stops here yet", systemImage: "mappin",
                                           description: Text("A way starts at one of your stops. Add the stop you get on at first."))
                }
            }
            .navigationTitle("Get on at")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// Where you get off: the stops after yours, on your line going your way.
private struct AlightPicker: View {
    let board: Selection
    let onPick: (TripWay) -> Void
    @State private var stops: [Stop]?

    var body: some View {
        List(stops ?? []) { stop in
            Button {
                onPick(TripWay(board: board, alightCode: stop.code, alightName: stop.name))
            } label: {
                Text(stop.name).foregroundStyle(.primary)
            }
        }
        .overlay {
            if stops == nil { ProgressView() } else if stops?.isEmpty == true {
                ContentUnavailableView("No stops after this one", systemImage: "signpost.right")
            }
        }
        .navigationTitle("Get off at")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let line = Line(id: board.lineID, name: board.lineName, mode: "bus")
            let directions = (try? await TransitService.directions(for: line, in: board.city)) ?? []
            let direction = directions.first { $0.id == board.directionID } ?? directions.first
            let all = direction?.stops ?? []
            let after = all.firstIndex { $0.code == board.stopCode }.map { Array(all[($0 + 1)...]) } ?? all
            stops = after
        }
    }
}

extension TripWay {
    /// "37", "S/K/M, then the 37".
    var lineSummary: String {
        let first = board.lineIDs.joined(separator: "/")
        return next.map { "\(first), then the \($0.board.lineIDs.joined(separator: "/"))" } ?? first
    }

    /// "Castro → Montgomery", "Montgomery → Church, then 14th St & Church St → Buena Vista Ave E".
    var stopsSummary: String {
        guard let next else { return "\(board.stopName) → \(alightName)" }
        return "\(board.stopName) → \(next.fromName), then \(next.board.stopName) → \(alightName)"
    }

    /// "Walk 12 min ↓97 m, change 1 min, then 4 min".
    var walkSummary: String {
        var parts = ["Walk \(Walk.describe(walkBeforeMinutes, climb: climbBefore))"]
        if let next, next.changeMinutes > 0 { parts.append("change \(Walk.describe(next.changeMinutes, climb: next.changeClimb))") }
        parts.append("then \(Walk.describe(walkMinutes, climb: climbAfter))")
        return parts.joined(separator: ", ")
    }
}

/// A way's lines: the first ride's badges, and with a change, an arrow and the second's.
struct WayBadges: View {
    let way: TripWay

    var body: some View {
        HStack(spacing: 3) {
            LineBadges(parts: way.board.badgeParts, font: .system(.subheadline, design: .rounded).weight(.heavy), round: way.board.roundBadge)
            if let next = way.next {
                Image(systemName: "arrow.right").font(.caption2.weight(.bold)).opacity(0.7)
                LineBadges(parts: next.board.badgeParts, font: .system(.subheadline, design: .rounded).weight(.heavy), round: next.board.roundBadge)
            }
        }
        .fixedSize()
    }
}

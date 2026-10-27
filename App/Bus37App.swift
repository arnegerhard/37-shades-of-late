import SwiftUI
import WidgetKit

@main
struct Bus37App: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let screen = ScreenshotScreen.current, [.widgets, .lock, .lockwidget].contains(screen) {
                WidgetShowcase(screen: screen)
            } else {
                ContentView()
            }
            #else
            ContentView()
            #endif
        }
    }
}

struct ContentView: View {
    @State private var selection = Selection.current
    @State private var feed = DepartureFeed()
    @State private var favoritesFeed = FavoritesFeed()
    @State private var choosing = false
    @State private var pickerPath: [Line] = []
    @State private var showingMap = false
    /// The stop that was open before a favorite's live map button, to go back to after the map.
    @State private var openBeforeMap: Selection?
    @State private var favorites = Selection.favorites
    @State private var showingGuide = !WidgetGuide.hasBeenShown

    private var departures: [Departure] { feed.departures }
    private var loaded: Selection? { feed.loaded }
    private var isStale: Bool { loaded?.id != selection.id }

    private var isFavorite: Bool { favorites.contains { $0.id == selection.id } }

    var body: some View {
        NavigationStack {
            List {
                // The map is how you pick a ride: it previews the open route and its buses, and
                // tapping it opens every line in the city to choose a ride, direction and stop.
                Section {
                    CityPager(cities: City.allCases, city: selection.city, onSwitch: switchCity(to:)) { city in
                        // Room at the top for the open favorite's card, so the route isn't under it.
                        RouteMap(selection: preview(for: city), feed: feed, interactive: false,
                                 topInset: isFavorite && city == selection.city ? 44 : 0)
                            .allowsHitTesting(false)
                    }
                    .frame(height: 260)
                    .contentShape(Rectangle())
                    .onTapGesture { choosing = true }
                    .overlay(alignment: .topLeading) {
                        if isFavorite {
                            openFavoriteCard
                                .padding(10)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        // Says out loud what tapping the map does; the map alone reads as a picture.
                        Button { choosing = true } label: {
                            Label("Add favorite", systemImage: "plus.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.regularMaterial, in: Capsule())
                        }
                        .buttonStyle(.borderless)
                        .padding(12)
                    }
                    .listRowInsets(EdgeInsets())
                } header: {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Tap the map to pick your next wait", systemImage: "hand.tap.fill")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Picker("City", selection: Binding(get: { selection.city }, set: { switchCity(to: $0) })) {
                            ForEach(City.allCases) { Text($0.name).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    .textCase(nil)
                    .padding(.bottom, 4)
                }

                // A city's default stop, before you've picked anything there.
                if !isFavorite {
                    Section {
                        stopCard
                    } footer: {
                        if favorites.isEmpty {
                            Text("Your widgets wait for this one until you save favorites of your own.")
                        }
                    }
                }

                Section {
                    if favorites.isEmpty {
                        Button { choosing = true } label: {
                            Label("No favorites yet. Tap the map to start curating your suffering. It shows up here and on your widgets.", systemImage: "plus.circle")
                                .font(.subheadline)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    ForEach(favorites) { favorite in
                        // Tapping a favorite opens it on the map above; its own buttons open the live
                        // map, or reorder it (hold and drag).
                        HStack(spacing: 8) {
                            Button { select(favorite) } label: { favoriteRow(favorite) }
                            .buttonStyle(.borderless)
                            .tint(.primary)
                            liveMapButton(for: favorite)
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.tertiary)
                                .frame(width: 20, height: 44)
                                .contentShape(Rectangle())
                                .accessibilityHidden(true)
                        }
                        .listRowBackground(favoriteBackground(isSelected: favorite.id == selection.id))
                    }
                    .onDelete { favorites.remove(atOffsets: $0) }
                    .onMove { favorites.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Favorites").textCase(nil)
                } footer: {
                    if !favorites.isEmpty {
                        Text("Your widgets suffer in this order; the small ones only have room for the top one. The full-screen button lets you watch the bus not move, live. Hold and drag to reorder, swipe to delete.")
                    }
                }

                Section {
                    Button { showingGuide = true } label: {
                        Label("Put your buses on the Lock Screen", systemImage: "lock.iphone")
                            .font(.subheadline.weight(.semibold))
                    }
                } footer: {
                    Text("Be let down without even unlocking your phone. Takes 30 seconds, less than any bus.")
                }
            }
            .navigationTitle("37 Shades of Late")
            .refreshable { await feed.reload() }
            .navigationDestination(isPresented: $showingMap) {
                RouteMap(selection: selection, feed: feed)
                    .navigationTitle(selection.isMultiLine ? "\(selection.lineIDs.joined(separator: ", ")) to \(selection.destination)" : "\(selection.lineID) \(selection.lineName)")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.visible, for: .navigationBar)
            }
            .onChange(of: showingMap) {
                // Back from a favorite's live map: open what was open before, so the big card
                // stays the one you chose.
                guard !showingMap, let previous = openBeforeMap else { return }
                openBeforeMap = nil
                select(previous)
            }
            .task(id: selection) { await feed.follow(selection) }
            .task(id: favorites) { await favoritesFeed.follow(favorites) }
            .task { await startInNearestCity() }
            .onChange(of: favorites) {
                Selection.favorites = favorites
                // The widgets list the favorites in order, so any change shows up there right away.
                WidgetCenter.shared.reloadAllTimelines()
            }
            #if DEBUG
            .onAppear {
                switch ScreenshotScreen.current {
                case .guide: showingGuide = true
                case .lines: choosing = true
                case .map: showingMap = true
                case .stops:
                    choosing = true
                    pickerPath = [Line(id: selection.lineID, name: selection.lineName, mode: "bus")]
                default: break
                }
            }
            #endif
            .sheet(isPresented: $choosing) {
                NavigationStack(path: $pickerPath) {
                    LinePicker { picked in
                        // Picking a stop saves it: it joins the favorites (at the end) and opens.
                        if !favorites.contains(where: { $0.id == picked.id }) { favorites.append(picked) }
                        select(picked)
                        choosing = false
                        pickerPath = []
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { choosing = false } }
                    }
                }
            }
            .fullScreenCover(isPresented: $showingGuide) {
                WidgetGuide {
                    WidgetGuide.hasBeenShown = true
                    showingGuide = false
                }
            }
        }
    }

    /// The favorite open on the map gets a thin frame in the line-badge red. It's only a marker.
    private func favoriteBackground(isSelected: Bool) -> some View {
        Color(.secondarySystemGroupedBackground)
            .overlay {
                if isSelected { SelectedFavoriteFrame() }
            }
    }

    /// The line and where it goes, the stop, and a comment on the wait; the next departure on the
    /// right, big, with the two after it underneath. Everything stays on its line and truncates
    /// instead of wrapping.
    private func favoriteRow(_ favorite: Selection) -> some View {
        TimelineView(.everyMinute) { context in
            let loaded = favoritesFeed.departures[favorite.id]
            let upcoming = (loaded ?? []).filter { $0.time > context.date.addingTimeInterval(-30) }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        LineBadge(line: favorite.lineLabel, font: .system(.subheadline, design: .rounded).weight(.heavy))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .layoutPriority(1)
                        Text("To \(favorite.destination)").font(.subheadline.weight(.semibold))
                    }
                    HStack(spacing: 6) {
                        // Like the widgets: tag each favorite with its city once favorites span both.
                        if Set(favorites.map(\.city)).count > 1 {
                            Text(favorite.city.code).font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                        }
                        Text(favorite.stopName).font(.footnote).foregroundStyle(.secondary)
                    }
                    if loaded != nil {
                        // About the line that actually comes next.
                        QuipText(upcoming.first.map { Quip.forWait(until: $0.time, from: context.date, line: $0.line ?? favorite.lineLabel) }
                                 ?? Quip.noPrediction(line: favorite.lineLabel))
                            // The punchline matters: it may take a second line.
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Departure.waits(upcoming, from: context.date, count: 1, lines: favorite.isMultiLine)
                         ?? (loaded == nil ? "…" : "none"))
                        .font(.system(.headline, design: .rounded).weight(.semibold))
                        .foregroundStyle(upcoming.first?.isLive == true ? .green : .secondary)
                    if let later = Departure.waits(Array(upcoming.dropFirst()), from: context.date, count: 2, unit: false, lines: favorite.isMultiLine) {
                        Text(later)
                            .font(.system(.caption, design: .rounded).weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
    }

    /// A city's default stop before any favorite there: tapping it opens its live map.
    private var stopCard: some View {
        Button { showingMap = true } label: {
            HStack(spacing: 12) {
                stopCardContent
                Image(systemName: "map")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Live map")
            }
        }
        .tint(.primary)
    }

    /// The open stop: line, destination and stop, then the next three departures.
    private var stopCardContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if isFavorite, Set(favorites.map(\.city)).count > 1 {
                    CityTag(code: selection.city.code)
                }
                LineBadge(line: selection.lineLabel, font: .system(.title3, design: .rounded).weight(.heavy))
                VStack(alignment: .leading, spacing: 2) {
                    Text("To \(selection.destination)").font(.headline)
                    Text(selection.stopName).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            nextDepartures
        }
        .multilineTextAlignment(.leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// The open favorite, in one line over the top of the map: line, stop and the next departure.
    /// Tapping it opens the live map.
    private var openFavoriteCard: some View {
        Button { showingMap = true } label: {
            TimelineView(.everyMinute) { context in
                let shown = loaded ?? selection
                let next = departures.first { $0.time > context.date.addingTimeInterval(-30) }
                HStack(spacing: 8) {
                    LineBadge(line: selection.lineLabel, font: .system(.subheadline, design: .rounded).weight(.heavy))
                    Text(selection.stopName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if feed.error == nil, let first = Departure.waits(departures, from: context.date, count: 1, lines: shown.isMultiLine) {
                        Text(first)
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(next?.isLive == true ? .green : .secondary)
                            .lineLimit(1)
                            .fixedSize()
                            .opacity(isStale ? 0.4 : 1)
                    }
                }
                .padding(.leading, 6)
                .padding(.trailing, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the live map")
    }

    /// Opens a favorite's live map; back from it, the stop open before is open again.
    private func liveMapButton(for favorite: Selection) -> some View {
        Button {
            if favorite.id != selection.id { openBeforeMap = selection }
            select(favorite)
            showingMap = true
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .foregroundStyle(.tertiary)
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        // The same gray as the drag handle, not the accent color.
        .tint(.primary)
        .accessibilityLabel("Live map, \(favorite.lineLabel) to \(favorite.destination)")
    }

    /// The next three departures as minutes, like the widgets ("4 · 16 · 31 min"), plus a comment
    /// on the first. Recounted every minute between data refreshes.
    private var nextDepartures: some View {
        TimelineView(.everyMinute) { context in
            let shown = loaded ?? selection
            let line = shown.lineLabel
            VStack(alignment: .leading, spacing: 3) {
                if let error = feed.error {
                    Text(error).font(.subheadline).foregroundStyle(.secondary)
                } else if let waits = Departure.waits(departures, from: context.date, count: 3, lines: shown.isMultiLine) {
                    Text(waits)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(departures.first?.isLive == true ? .green : .secondary)
                    if let next = departures.first(where: { $0.time > context.date.addingTimeInterval(-30) }) {
                        // About the line that actually comes next.
                        QuipText(Quip.forWait(until: next.time, from: context.date, line: next.line ?? line))
                    }
                } else {
                    Text("No \(line)s on the horizon").font(.subheadline).foregroundStyle(.secondary)
                    QuipText(Quip.noPrediction(line: line))
                }
            }
            .padding(.leading, 2)
            .opacity(isStale ? 0.4 : 1)
        }
    }

    /// On a fresh install, start with the default stop of whichever supported city the proxy
    /// thinks we're in (a rough IP-based guess: no location permission, nothing stored).
    private func startInNearestCity() async {
        guard !Selection.hasSavedChoice else { return }
        let start = (await TransitService.nearestCity() ?? .sf).defaultSelection
        Selection.current = start
        if start.id != selection.id {
            withAnimation(Self.switchAnimation) { selection = start }
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Makes `picked` the line and stop shown in the app.
    private func select(_ picked: Selection) {
        guard picked.id != selection.id else { return }
        Selection.current = picked
        // Keep the old times on screen (dimmed) until the new ones arrive, so the list
        // resizes once, straight to its new height.
        withAnimation(Self.switchAnimation) { selection = picked }
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// What each city's map shows: the open stop for its city, else the stop switching there would open.
    private func preview(for city: City) -> Selection {
        city == selection.city ? selection : opening(city)
    }

    /// The stop switching to `city` opens: the one you last had open there if it's a favorite,
    /// else your first favorite there, else the city's default stop.
    private func opening(_ city: City) -> Selection {
        let cityFavorites = favorites.filter { $0.city == city }
        let last = Selection.lastOpened(in: city)
        return cityFavorites.first { $0.id == last?.id } ?? cityFavorites.first ?? city.defaultSelection
    }

    /// Switching city moves the map and the card to the new city. The widgets keep the favorites' order.
    private func switchCity(to city: City) {
        guard city != selection.city else { return }
        Selection.setLastOpened(selection)
        select(opening(city))
    }

    private static var switchAnimation: Animation { DepartureFeed.switchAnimation }
}

/// Editorial commentary on the wait, shown in small text under predictions in the app
/// (never on widgets).
enum Quip {
    static func forWait(until time: Date, from now: Date = .now, line: String) -> String {
        switch Int(time.timeIntervalSince(now) / 60) {
        case ..<4: "Holy shit, the \(line) is real."
        case ..<9: "Stay put, lazy bastard."
        case ..<16: "Make coffee. Reconsider your life."
        default: "Walking is starting to look attractive."
        }
    }

    static func noPrediction(line: String) -> String {
        "Schrödinger's \(line): both coming and not coming."
    }

    static func vanished(line: String) -> String {
        "The \(line) has entered the witness protection program."
    }
}

struct QuipText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .italic()
            .foregroundStyle(.secondary)
    }
}

/// Pages between cities with a finger: dragging slides the neighbor city's map in alongside the
/// current one, and letting go past a third of the width (or with a quick flick) switches to it.
private struct CityPager<Page: View>: View {
    let cities: [City]
    let city: City
    let onSwitch: (City) -> Void
    @ViewBuilder let page: (City) -> Page

    @GestureState private var drag: CGFloat = 0
    @State private var settle: CGFloat = 0
    @State private var width: CGFloat = 1

    private var index: CGFloat { CGFloat(cities.firstIndex(of: city) ?? 0) }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(cities) { page($0).frame(width: geometry.size.width) }
            }
            .offset(x: -index * geometry.size.width + drag + settle)
            .animation(.snappy(duration: 0.3), value: city)
            .onAppear { width = geometry.size.width }
            .onChange(of: geometry.size.width) { width = geometry.size.width }
        }
        .clipped()
        // On the whole frame: the pages themselves ignore touches so a tap reaches the picker.
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 20)
                .updating($drag) { value, state, _ in
                    let dx = value.translation.width
                    guard abs(dx) > abs(value.translation.height) else { return }
                    // Rubber-band past the first and last city.
                    let atEdge = (dx > 0 && index == 0) || (dx < 0 && Int(index) == cities.count - 1)
                    state = atEdge ? dx / 4 : dx
                }
                .onEnded { value in
                    let dx = value.predictedEndTranslation.width
                    let target = Int(index) + (dx < -width / 3 ? 1 : dx > width / 3 ? -1 : 0)
                    guard cities.indices.contains(target), target != Int(index) else { return }
                    // Hand the finger's offset over to the animation so the slide doesn't jump.
                    settle = value.translation.width + CGFloat(target - Int(index)) * width
                    onSwitch(cities[target])
                    withAnimation(.snappy(duration: 0.3)) { settle = 0 }
                }
        )
    }
}

/// Thin red outline for the favorite open on the map. Its corners follow the section's rounded
/// corners wherever the row is: after a drag the list doesn't redraw a moved row's background, so
/// a shape that depended on the row's position would keep its old one and get clipped.
private struct SelectedFavoriteFrame: View {
    private static let inset: CGFloat = 2

    /// Inset-grouped sections round their corners by about 26pt on iOS 26 and 10pt before.
    /// SwiftUI doesn't expose the value (and ConcentricRectangle doesn't see the row's
    /// container), so it's matched by hand.
    private static var radius: CGFloat {
        if #available(iOS 26, *) { 26 - inset } else { 10 }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            .strokeBorder(LineBadge.red.opacity(0.7), lineWidth: 2)
            .padding(Self.inset)
            .allowsHitTesting(false)
    }
}

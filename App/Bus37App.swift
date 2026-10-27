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
                        RouteMap(selection: preview(for: city), feed: feed, interactive: false)
                            .allowsHitTesting(false)
                    }
                    .frame(height: 220)
                    .contentShape(Rectangle())
                    .onTapGesture { choosing = true }
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
                        Label("Tap the map to add a ride and stop", systemImage: "hand.tap.fill")
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
                            Text("Your widgets show this line and stop until you save favorites.")
                        }
                    }
                }

                Section {
                    if favorites.isEmpty {
                        Button { choosing = true } label: {
                            Label("Tap the map to add your first favorite. It shows up here and on your widgets.", systemImage: "plus.circle")
                                .font(.subheadline)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    ForEach(favorites) { favorite in
                        // Tapping a favorite opens it; its own buttons open the live map, or reorder
                        // it (hold and drag).
                        HStack(spacing: 12) {
                            Button { select(favorite) } label: {
                                if favorite.id == selection.id {
                                    // The open favorite becomes the big card, right where it sits in the order.
                                    stopCardContent
                                } else {
                                    favoriteRow(favorite)
                                }
                            }
                            .buttonStyle(.borderless)
                            .tint(.primary)
                            liveMapButton(for: favorite)
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.tertiary)
                                .frame(width: 24, height: 44)
                                .contentShape(Rectangle())
                                .accessibilityHidden(true)
                        }
                    }
                    .onDelete { favorites.remove(atOffsets: $0) }
                    .onMove { favorites.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Favorites").textCase(nil)
                } footer: {
                    if !favorites.isEmpty {
                        Text("Your widgets show your favorites in this order; the small ones show the top one. The map button shows its buses live; hold and drag to reorder, swipe to delete.")
                    }
                }

                Section {
                    Button { showingGuide = true } label: {
                        Label("Put your buses on the Lock Screen", systemImage: "lock.iphone")
                            .font(.subheadline.weight(.semibold))
                    }
                } footer: {
                    Text("A 30-second walkthrough for adding the widget.")
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

    private func favoriteRow(_ favorite: Selection) -> some View {
        HStack(spacing: 12) {
            // Like the widgets: tag each favorite with its city once favorites span both.
            if Set(favorites.map(\.city)).count > 1 {
                CityTag(code: favorite.city.code)
            }
            LineBadge(line: favorite.lineLabel, font: .system(.body, design: .rounded).weight(.heavy))
                .frame(minWidth: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text("To \(favorite.destination)").font(.subheadline.weight(.semibold))
                Text(favorite.stopName).font(.footnote).foregroundStyle(.secondary)
                TimelineView(.everyMinute) { context in
                    let upcoming = favoritesFeed.departures[favorite.id] ?? []
                    Text(Departure.waits(upcoming, from: context.date, count: 3, lines: favorite.isMultiLine) ?? (favoritesFeed.departures[favorite.id] == nil ? "…" : "none"))
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(upcoming.first?.isLive == true ? .green : .secondary)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        // Buttons center wrapped text; a long stop name should wrap like the rest of the list.
        .multilineTextAlignment(.leading)
        .contentShape(Rectangle())
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

    /// Opens a favorite's live map; back from it, the stop open before is open again.
    private func liveMapButton(for favorite: Selection) -> some View {
        Button {
            if favorite.id != selection.id { openBeforeMap = selection }
            select(favorite)
            showingMap = true
        } label: {
            Image(systemName: "map")
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
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
                    Text("No upcoming \(line)s").font(.subheadline).foregroundStyle(.secondary)
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

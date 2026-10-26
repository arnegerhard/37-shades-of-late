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
    @State private var favorites = Selection.favorites

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
                    .listRowInsets(EdgeInsets())
                } header: {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Select your ride and stop to track", systemImage: "hand.tap.fill")
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

                if !isFavorite {
                    Section {
                        stopCard
                    } header: {
                        HStack {
                            Spacer()
                            Button("Save", systemImage: "star") { toggleFavorite() }
                                .font(.subheadline.weight(.semibold))
                                .tint(.orange)
                        }
                        .textCase(nil)
                    } footer: {
                        if favorites.isEmpty {
                            Text("Your widgets show this line and stop until you save favorites.")
                        }
                    }
                }

                Section {
                    if favorites.isEmpty {
                        Label("Pick a ride on the map, then tap Save to keep it here and on your widgets.", systemImage: "star")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(favorites) { favorite in
                        Group {
                            if favorite.id == selection.id {
                                // The open favorite becomes the big card, right where it sits in the order.
                                stopCard
                            } else {
                                Button { select(favorite) } label: { favoriteRow(favorite) }
                                    .tint(.primary)
                            }
                        }
                        .listRowBackground(favoriteBackground(
                            isSelected: favorite.id == selection.id,
                            isFirst: favorite.id == favorites.first?.id,
                            isLast: favorite.id == favorites.last?.id))
                    }
                    .onDelete { favorites.remove(atOffsets: $0) }
                    .onMove { favorites.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Favorites").textCase(nil)
                } footer: {
                    if !favorites.isEmpty {
                        Text("Your widgets show the open one first, then the rest in this order. Tap one to open it, hold and drag to reorder, swipe to delete.")
                    }
                }

                Section {
                    Text("Add the widget from your Home Screen or Lock Screen: touch and hold, tap Edit or Customize, then search for \"37 Shades of Late\".")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("37 Shades of Late")
            .refreshable { await feed.reload() }
            .navigationDestination(isPresented: $showingMap) {
                RouteMap(selection: selection, feed: feed)
                    .navigationTitle("\(selection.lineID) \(selection.lineName)")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.visible, for: .navigationBar)
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
                        select(picked)
                        choosing = false
                        pickerPath = []
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { choosing = false } }
                    }
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
            LineBadge(line: favorite.lineID, font: .system(.body, design: .rounded).weight(.heavy))
                .frame(minWidth: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text("To \(favorite.destination)").font(.subheadline.weight(.semibold))
                Text(favorite.stopName).font(.footnote).foregroundStyle(.secondary)
                TimelineView(.everyMinute) { context in
                    let upcoming = favoritesFeed.departures[favorite.id] ?? []
                    Text(Departure.waits(upcoming, from: context.date, count: 3) ?? (favoritesFeed.departures[favorite.id] == nil ? "…" : "none"))
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(upcoming.first?.isLive == true ? .green : .secondary)
                }
                .padding(.top, 2)
            }
            Spacer()
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .accessibilityAddTraits(favorite.id == selection.id ? .isSelected : [])
    }

    /// The favorite open in the app gets a thin frame in the line-badge red.
    private func favoriteBackground(isSelected: Bool, isFirst: Bool, isLast: Bool) -> some View {
        Color(.secondarySystemGroupedBackground)
            .overlay {
                if isSelected { SelectedFavoriteFrame(isFirst: isFirst, isLast: isLast) }
            }
    }

    /// The open stop: line, destination and stop, then the next three departures. Tapping it opens
    /// the live map of that ride; a different ride is picked on the map above.
    private var stopCard: some View {
        Button { showingMap = true } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    if isFavorite, Set(favorites.map(\.city)).count > 1 {
                        CityTag(code: selection.city.code)
                    }
                    LineBadge(line: selection.lineID, font: .system(.title3, design: .rounded).weight(.heavy))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("To \(selection.destination)").font(.headline)
                        Text(selection.stopName).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "map")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Live map")
                }
                nextDepartures
            }
            .padding(.vertical, 4)
        }
        .tint(.primary)
    }

    /// The next three departures as minutes, like the widgets ("4 · 16 · 31 min"), plus a comment
    /// on the first. Recounted every minute between data refreshes.
    private var nextDepartures: some View {
        TimelineView(.everyMinute) { context in
            let line = (loaded ?? selection).lineID
            VStack(alignment: .leading, spacing: 3) {
                if let error = feed.error {
                    Text(error).font(.subheadline).foregroundStyle(.secondary)
                } else if let waits = Departure.waits(departures, from: context.date, count: 3) {
                    Text(waits)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(departures.first?.isLive == true ? .green : .secondary)
                    if let next = departures.first(where: { $0.time > context.date.addingTimeInterval(-30) }) {
                        QuipText(Quip.forWait(until: next.time, from: context.date, line: line))
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

    /// Makes `picked` the line and stop shown in the app, and first on the widgets.
    private func select(_ picked: Selection) {
        guard picked.id != selection.id else { return }
        Selection.current = picked
        // The widgets lead with the open stop, so they change along with it (reloaded below).
        // Keep the old times on screen (dimmed) until the new ones arrive, so the list
        // resizes once, straight to its new height.
        withAnimation(Self.switchAnimation) { selection = picked }
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// What each city's map shows: the open stop for its city, else the stop switching there would open.
    private func preview(for city: City) -> Selection {
        city == selection.city ? selection : (favorites.first { $0.city == city } ?? city.defaultSelection)
    }

    /// Switching city opens your first favorite there, or that city's default stop if you have
    /// none, so the map, the card and the widgets all move to the new city.
    private func switchCity(to city: City) {
        guard city != selection.city else { return }
        select(favorites.first { $0.city == city } ?? city.defaultSelection)
    }

    private func toggleFavorite() {
        if let index = favorites.firstIndex(where: { $0.id == selection.id }) {
            favorites.remove(at: index)
        } else {
            favorites.append(selection)
        }
    }

    private static var switchAnimation: Animation { DepartureFeed.switchAnimation }
}

/// Thin red outline for the favorite open in the app. The first and last rows sit in the
/// section's rounded corners, so their outer corners follow those instead of being clipped.
private struct SelectedFavoriteFrame: View {
    let isFirst: Bool
    let isLast: Bool

    private static let inset: CGFloat = 2
    private static let innerRadius: CGFloat = 12

    /// Inset-grouped sections round their corners by about 26pt on iOS 26 and 10pt before.
    /// SwiftUI doesn't expose the value (and ConcentricRectangle doesn't see the row's
    /// container), so it's matched by hand.
    private static var outerRadius: CGFloat {
        if #available(iOS 26, *) { 26 - inset } else { innerRadius }
    }

    var body: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? Self.outerRadius : Self.innerRadius,
            bottomLeadingRadius: isLast ? Self.outerRadius : Self.innerRadius,
            bottomTrailingRadius: isLast ? Self.outerRadius : Self.innerRadius,
            topTrailingRadius: isFirst ? Self.outerRadius : Self.innerRadius,
            style: .continuous
        )
        .strokeBorder(LineBadge.red.opacity(0.7), lineWidth: 2)
        .padding(Self.inset)
    }
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

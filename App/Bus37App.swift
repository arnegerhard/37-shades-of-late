import SwiftUI
import WidgetKit

@main
struct Bus37App: App {
    #if DEBUG
    init() { ScreenshotScreen.seedFavoritesIfAsked() }
    #endif

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
    /// The stop being shared, from the home map or the live map.
    @State private var sharing: Selection?
    /// A stop from a shared link, waiting for "Add".
    @State private var incoming: Selection?
    @State private var favorites = Selection.favorites
    @State private var showingGuide = !WidgetGuide.hasBeenShown
    /// Whether the map has been tapped (opening the line picker) at least once; after that, the hint
    /// above it isn't needed any more.
    @AppStorage("mapHintDone") private var mapHintDone = false
    /// The city whose favorites are in edit mode (deleting); a sideways swipe turns the page instead.
    @State private var editingCity: City?
    /// How far each city's list is scrolled; the hint and city picker slide away by as much (up to
    /// their own height) to give the pinned map their room.
    @State private var scrollOffsets: [City: CGFloat] = [:]
    @State private var headerHeight: CGFloat = 0

    private var departures: [Departure] { feed.departures }
    private var loaded: Selection? { feed.loaded }
    private var isStale: Bool { loaded?.id != selection.id }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                // The title is drawn here rather than by the navigation bar, which would follow the
                // lists' scrolling and shift the pages under it a moment after a scroll comes to rest.
                Text("37 Shades of Late")
                    .font(.largeTitle.bold())
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                    .accessibilityAddTraits(.isHeader)
                // A page per city, each with its own map, open stop and favorites; swiping anywhere
                // switches city and the page slides along. The hint and city picker stay put above
                // the pages (each page leaves room for them), sliding up only as the list scrolls.
                ZStack(alignment: .top) {
                    TabView(selection: Binding(get: { selection.city }, set: { switchCity(to: $0) })) {
                        ForEach(City.allCases) { city in
                            cityPage(city).tag(city)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))

                    cityHeader
                        .background(Color(.systemGroupedBackground))
                        .offset(y: -collapse(selection.city))
                        .opacity(headerHeight > 0 ? 1 - collapse(selection.city) / headerHeight : 1)
                        .allowsHitTesting(collapse(selection.city) < headerHeight / 2)
                }
                .clipped()
            }
            .background(Color(.systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showingMap) {
                RouteMap(selection: selection, feed: feed)
                    .navigationTitle(selection.isMultiLine ? "\(selection.lineIDs.joined(separator: ", ")) to \(selection.destination)" : "\(selection.lineID) \(selection.lineName)")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.visible, for: .navigationBar)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { sharing = selection } label: { Image(systemName: "square.and.arrow.up") }
                                .accessibilityLabel("Share this stop")
                        }
                    }
                    .sheet(item: $sharing) { stop in
                        ShareSheet(selection: stop, departures: shownDepartures(for: stop).departures)
                    }
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
            // A friend's stop, from a 37shadesoflate.com/s link (or its QR code).
            .onOpenURL { url in Task { incoming = await Selection.shared(by: url) } }
            .alert(incoming.map { "Add the \($0.lineLabel) at \($0.stopName)?" } ?? "",
                   isPresented: Binding(get: { incoming != nil }, set: { if !$0 { incoming = nil } })) {
                Button("Add to favorites") {
                    if let picked = incoming {
                        if !favorites.contains(where: { $0.id == picked.id }) { favorites.append(picked) }
                        select(picked)
                    }
                }
                Button("Not now", role: .cancel) {}
            } message: {
                if let incoming { Text("To \(incoming.destination), in \(incoming.city.name). It joins your favorites there.") }
            }
            .onChange(of: favorites) {
                Selection.favorites = favorites
                // The widgets list the favorites in order, so any change shows up there right away.
                WidgetCenter.shared.reloadAllTimelines()
            }
            #if DEBUG
            .task {
                // `-openLink <url>`: as if a shared link were opened.
                if let link = UserDefaults.standard.string(forKey: "openLink").flatMap(URL.init(string:)) {
                    incoming = await Selection.shared(by: link)
                }
            }
            .onAppear {
                switch ScreenshotScreen.current {
                case .guide: showingGuide = true
                case .share:
                    showingMap = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); sharing = selection }
                case .lines: choosing = true
                case .map: showingMap = true
                case .stops:
                    choosing = true
                    // After the sheet is up: pushed in the same moment, the title draws twice.
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        pickerPath = [Line(id: selection.lineID, name: selection.lineName, mode: "bus")]
                    }
                default: break
                }
            }
            #endif
            .onChange(of: choosing) {
                if choosing, !mapHintDone {
                    // Shown once more under the picker sheet, then gone once it closes.
                    Task { try? await Task.sleep(for: .seconds(0.6)); mapHintDone = true }
                }
            }
            .sheet(item: Binding(get: { showingMap ? nil : sharing }, set: { sharing = $0 })) { stop in
                ShareSheet(selection: stop, departures: shownDepartures(for: stop).departures)
            }
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

    /// One city: the map previewing its open stop (tap it to pick another), that stop's departures
    /// while it isn't a favorite, and the city's favorites.
    private func cityPage(_ city: City) -> some View {
        let open = preview(for: city)
        let cityFavorites = favorites.filter { $0.city == city }
        let openIsFavorite = cityFavorites.contains { $0.id == open.id }
        // The map stays pinned above the list, moving up into the header's room once the list
        // scrolls, so a favorite picked far down a long list still shows on it.
        return ZStack(alignment: .top) {
            List {
                // The city's default stop, before you've picked anything there.
                if !openIsFavorite {
                    Section {
                        stopCard(open)
                    } footer: {
                        if cityFavorites.isEmpty {
                            Text("Your widgets wait for this one in \(city.name) until you save favorites of your own.")
                        }
                    }
                }

                Section {
                    if cityFavorites.isEmpty {
                        Button { choosing = true } label: {
                            Label("No favorites in \(city.name) yet. Tap the map to start curating your suffering. It shows up here and on your widgets.", systemImage: "plus.circle")
                                .font(.subheadline)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    ForEach(cityFavorites) { favorite in
                        // Tapping a favorite opens it on the map above; its own buttons open the live
                        // map, or reorder it (hold and drag).
                        HStack(spacing: 8) {
                            Button { select(favorite) } label: { favoriteRow(favorite) }
                            .buttonStyle(.borderless)
                            .tint(.primary)
                            liveMapButton(for: favorite)
                            // In edit mode the list draws its own handle.
                            if editingCity != city {
                                Image(systemName: "line.3.horizontal")
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 20, height: 44)
                                    .contentShape(Rectangle())
                                    .accessibilityHidden(true)
                            }
                        }
                        .listRowBackground(favoriteBackground(isSelected: favorite.id == open.id))
                        // Only in edit mode: otherwise a sideways swipe on a row is for turning the page.
                        .deleteDisabled(editingCity != city)
                    }
                    .onDelete { offsets in
                        let gone = Set(offsets.map { cityFavorites[$0].id })
                        favorites.removeAll { gone.contains($0.id) }
                    }
                    .onMove { from, to in
                        // Only this city's order changes; each city keeps its own list.
                        var reordered = cityFavorites
                        reordered.move(fromOffsets: from, toOffset: to)
                        favorites = favorites.filter { $0.city != city } + reordered
                    }
                } header: {
                    HStack {
                        Text("Favorites")
                        Spacer()
                        if !cityFavorites.isEmpty {
                            Button(editingCity == city ? "Done" : "Edit") {
                                withAnimation { editingCity = editingCity == city ? nil : city }
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                    }
                    .textCase(nil)
                } footer: {
                    // The Lock Screen button lives in the favorites' footer rather than a section of its
                    // own: a favorite dragged past the last row would otherwise land in that section,
                    // where it can't go, and snap back instead of moving to the end.
                    VStack(alignment: .leading, spacing: 10) {
                        if !cityFavorites.isEmpty {
                            Text("When you're in \(city.name), your widgets suffer in this order; the small ones only have room for the top one. The full-screen button lets you watch the \(city.vehicle) not move, live. Hold and drag to reorder; Edit to delete.")
                        }
                        Button { showingGuide = true } label: {
                            Label("Put your \(city.vehicles) on the Lock Screen", systemImage: "lock.iphone")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 14)
                                .background(Color(.secondarySystemGroupedBackground),
                                            in: RoundedRectangle(cornerRadius: ListCorners.radius, style: .continuous))
                        }
                        .tint(Color.accentColor)
                        .padding(.horizontal, -20)
                        .padding(.top, 14)
                        Text("Be let down without even unlocking your phone. Takes 30 seconds, less than any \(city.vehicle).")
                    }
                    .textCase(nil)
                }
            }
            .environment(\.editMode, .constant(editingCity == city ? .active : .inactive))
            .refreshable { await feed.reload() }
            // The list starts below the hint, picker and map, and scrolls on under them.
            // As safe area rather than a content margin, so the list knows that's where its visible top is:
            // a favorite dragged up there scrolls the list, instead of having to go up under the map.
            .safeAreaPadding(.top, headerHeight + 260 + 16)
            .modifier(ScrollOffset { scrollOffsets[city] = $0 })

            // The hint and city picker, then the map. Scrolling the list slides the hint and picker
            // up out of sight (and the map with them, into their room), in step with the finger.
            VStack(alignment: .leading, spacing: 0) {
                // The hint and city picker's room; they're drawn once, above the pages.
                Color.clear.frame(height: headerHeight)
                // Room at the top for the open favorite's card, so the route isn't under it.
                RouteMap(selection: open, feed: feed, interactive: false, topInset: openIsFavorite ? 44 : 0)
                    .allowsHitTesting(false)
                    .frame(height: 260)
                    .contentShape(Rectangle())
                    .onTapGesture { choosing = true }
                    .overlay(alignment: .topLeading) {
                        if openIsFavorite {
                            openFavoriteCard(open)
                                .padding(10)
                                // Clear of the share button.
                                .padding(.trailing, 48)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        Button { sharing = open } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 38, height: 38)
                                .background(.regularMaterial, in: Circle())
                        }
                        .buttonStyle(.borderless)
                        .padding(10)
                        .accessibilityLabel("Share this stop")
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
                    .clipShape(RoundedRectangle(cornerRadius: ListCorners.radius, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            // Covers the rows scrolling up underneath, from the top of the page to below the map.
            .background(alignment: .bottom) {
                Color(.systemGroupedBackground).frame(height: 2000)
            }
            .offset(y: -collapse(city))
        }
        .clipped()
    }

    /// "Tap the map…" (until the map's been used) and the city picker, above the city pages.
    private var cityHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !mapHintDone {
                Label("Tap the map to pick your next wait", systemImage: "hand.tap.fill")
                    .font(.headline)
            }
            Picker("City", selection: Binding(get: { selection.city }, set: { switchCity(to: $0) })) {
                ForEach(City.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { headerHeight = $0 }
    }

    /// How far the header has slid away for `city`: as far as its list is scrolled, up to its height.
    private func collapse(_ city: City) -> CGFloat {
        min(max(scrollOffsets[city] ?? 0, 0), headerHeight)
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
                    Text(favorite.stopName).font(.footnote).foregroundStyle(.secondary)
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
    private func stopCard(_ open: Selection) -> some View {
        Button { showingMap = true } label: {
            HStack(spacing: 12) {
                stopCardContent(open)
                Image(systemName: "map")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Live map")
            }
        }
        .tint(.primary)
    }

    /// The open stop: line, destination and stop, then the next three departures.
    private func stopCardContent(_ open: Selection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                LineBadge(line: open.lineLabel, font: .system(.title3, design: .rounded).weight(.heavy))
                VStack(alignment: .leading, spacing: 2) {
                    Text("To \(open.destination)").font(.headline)
                    Text(open.stopName).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            nextDepartures(open)
        }
        .multilineTextAlignment(.leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// The open favorite, in one line over the top of the map: line, stop and the next departure.
    /// Tapping it opens the live map.
    private func openFavoriteCard(_ open: Selection) -> some View {
        Button { showingMap = true } label: {
            TimelineView(.everyMinute) { context in
                let (departures, dimmed) = shownDepartures(for: open)
                let next = departures.first { $0.time > context.date.addingTimeInterval(-30) }
                HStack(spacing: 8) {
                    LineBadge(line: open.lineLabel, font: .system(.subheadline, design: .rounded).weight(.heavy))
                        // The whole line name ("HOB–33"); the stop name gives way instead.
                        .fixedSize()
                    Text(open.stopName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if open.id != selection.id || feed.error == nil,
                       let first = Departure.waits(departures, from: context.date, count: 1, lines: open.isMultiLine) {
                        Text(first)
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(next?.isLive == true ? .green : .secondary)
                            .lineLimit(1)
                            .fixedSize()
                            .opacity(dimmed ? 0.4 : 1)
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
    private func nextDepartures(_ open: Selection) -> some View {
        TimelineView(.everyMinute) { context in
            let isOpen = open.id == selection.id
            let shown = isOpen ? loaded ?? selection : open
            let line = shown.lineLabel
            let (departures, dimmed) = shownDepartures(for: open)
            VStack(alignment: .leading, spacing: 3) {
                if isOpen, let error = feed.error {
                    Text(error).font(.subheadline).foregroundStyle(.secondary)
                } else if !isOpen && departures.isEmpty {
                    // Another city's default stop, seen mid-swipe: its times load once it's open.
                    Text("…").font(.system(.title3, design: .rounded).weight(.semibold)).foregroundStyle(.secondary)
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
            .opacity(dimmed ? 0.4 : 1)
        }
    }

    /// The departures a city page shows for `open`: the open stop's live feed (dimmed while it
    /// still holds the previous stop's), or for another city's page, what the favorites feed has.
    private func shownDepartures(for open: Selection) -> (departures: [Departure], dimmed: Bool) {
        if open.id == selection.id { return (departures, isStale) }
        return (favoritesFeed.departures[open.id] ?? [], false)
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
        editingCity = nil
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

/// Thin red outline for the favorite open on the map. Its corners follow the section's rounded
/// corners wherever the row is: after a drag the list doesn't redraw a moved row's background, so
/// a shape that depended on the row's position would keep its old one and get clipped.
private struct SelectedFavoriteFrame: View {
    private static let inset: CGFloat = 2
    private static var radius: CGFloat { ListCorners.radius - inset }

    var body: some View {
        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            .strokeBorder(LineBadge.red.opacity(0.7), lineWidth: 2)
            .padding(Self.inset)
            .allowsHitTesting(false)
    }
}

/// Inset-grouped sections round their corners by about 26pt on iOS 26 and 10pt before. SwiftUI
/// doesn't expose the value (and ConcentricRectangle doesn't see a row's container), so it's
/// matched by hand, for the map card and the selected favorite's frame.
private enum ListCorners {
    static var radius: CGFloat {
        if #available(iOS 26, *) { 26 } else { 12 }
    }
}

/// Reports how far a list is scrolled down from its top. Needs iOS 18; before that the header
/// just stays where it is.
private struct ScrollOffset: ViewModifier {
    let onChange: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, new in
                onChange(new)
            }
        } else {
            content
        }
    }
}

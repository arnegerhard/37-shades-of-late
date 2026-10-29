import SwiftUI
import TipKit
import WidgetKit

@main
struct Bus37App: App {
    init() {
        #if DEBUG
        ScreenshotScreen.seedFavoritesIfAsked()
        // `-resetTips YES`: as if no tip had been seen, closed or outgrown; `-showTips YES`: every tip,
        // whatever its rules say.
        if UserDefaults.standard.bool(forKey: "resetTips") { try? Tips.resetDatastore() }
        if UserDefaults.standard.bool(forKey: "showTips") { Tips.showAllTipsForTesting() }
        // `-fakeAway YES`: the Lock Screen widgets asleep, as far from every city (see WidgetPlace.debug).
        WidgetPlace.setDebugFromLaunchArguments()
        WidgetCenter.shared.reloadAllTimelines()
        #endif
        try? Tips.configure()
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let screen = ScreenshotScreen.current, [.widgets, .lock, .lockwidget].contains(screen) {
                WidgetShowcase(screen: screen)
            } else {
                ContentView().overlay { IslandShowOffView() }
            }
            #else
            // Over everything, where the island is: it opens out there when handed a watch.
            ContentView().overlay { IslandShowOffView() }
            #endif
        }
    }
}

struct ContentView: View {
    @State private var selection = Selection.current
    @State private var feed = DepartureFeed()
    @State private var favoritesFeed = FavoritesFeed()
    @Environment(\.scenePhase) private var scenePhase
    @State private var choosing = false
    @State private var pickerPath: [Line] = []
    /// The live map, blown up from the home map.
    @State private var showingMap = false
    @Namespace private var mapZoom
    /// The stop being shared, from the home map or the live map.
    @State private var sharing: Selection?
    /// A stop from a shared link, waiting for "Add".
    @State private var incoming: Selection?
    @State private var favorites = Selection.favorites
    @State private var showingGuide = !WidgetGuide.hasBeenShown
    /// The city whose favorites are in edit mode (deleting); a sideways swipe turns the page instead.
    @State private var editingCity: City?
    /// How far each city's list is scrolled; the hint and city picker slide away by as much (up to
    /// their own height) to give the pinned map their room.
    @State private var scrollOffsets: [City: CGFloat] = [:]
    @State private var headerHeight: CGFloat = 0
    /// The height of a city's page, for the map's two thirds of it.
    @State private var pageHeight: CGFloat = 0
    /// How much each city's map has shrunk, once its list is at rest.
    @State private var restingShrink: [City: CGFloat] = [:]
    /// The home map's pill hopping toward the island, the first time it's there: it goes up there.
    @State private var pillNudge: CGFloat = 0
    @AppStorage("pillNudged") private var pillNudged = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                RouteMap(selection: selection, feed: feed, onClose: { showingMap = false }, onShare: { sharing = selection })
                    // The map draws its own header, with a button that shrinks it back.
                    .toolbar(.hidden, for: .navigationBar)
                    .sheet(item: $sharing) { stop in
                        ShareSheet(selection: stop, departures: shownDepartures(for: stop).departures)
                    }
                    // Grows out of the home map it was tapped on; its header or card pulled down shrinks it back.
                    .modifier(ZoomTransition(id: selection.city, in: mapZoom))
            }
            // Only a favorite's times are shown on the home screen; the live map follows its own.
            .task(id: favorites.contains { $0.id == selection.id } ? selection : nil) {
                if favorites.contains(where: { $0.id == selection.id }) { await feed.follow(selection) }
            }
            .task(id: favorites) { await favoritesFeed.follow(favorites) }
            .task { await startInNearestCity() }
            // Counts the visits with a favorite on the home map, for when to point out its pill.
            .task {
                StalkTip.canWatch = BusActivities.shared.isAvailable
                if !favorites.isEmpty { await StalkTip.homeWithFavorite.donate() }
            }
            // A Lock Screen row's tap (see OpenStopIntent): as the app opens, or once it's open.
            .onReceive(NotificationCenter.default.publisher(for: WidgetTap.notification)) { _ in takeWidgetTap() }
            .onChange(of: scenePhase) {
                guard scenePhase == .active else { return }
                takeWidgetTap()
                // Live Activities can't end themselves once their bus is gone.
                BusActivities.shared.endFinished()
            }
            .onOpenURL { url in
                // A widget tap: that line and stop on the live map.
                if let tapped = Selection(openURL: url) { return openFromWidget(tapped) }
                // A friend's stop, from a 37shadesoflate.com/s link (or its QR code).
                Task { incoming = await Selection.shared(by: url) }
            }
            .alert(incoming.map { "Add the \($0.spokenLines) at \($0.stopName)?" } ?? "",
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
            .sheet(item: Binding(get: { showingMap ? nil : sharing }, set: { sharing = $0 })) { stop in
                ShareSheet(selection: stop, departures: shownDepartures(for: stop).departures)
            }
            // Like the live map, the line picker grows out of the home map.
            .fullScreenCover(isPresented: $choosing) {
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
                .modifier(ZoomTransition(id: selection.city, in: mapZoom))
            }
            .fullScreenCover(isPresented: $showingGuide) {
                WidgetGuide {
                    WidgetGuide.hasBeenShown = true
                    showingGuide = false
                }
            }
        }
    }

    /// One city: the map showing its open favorite (tap it for the live map; Add favorite picks
    /// another stop) and the city's favorites. Before there are any, the map shows the city's main
    /// lines and the list says how it all works.
    private func cityPage(_ city: City) -> some View {
        let open = preview(for: city)
        let cityFavorites = favorites.filter { $0.city == city }
        let openIsFavorite = cityFavorites.contains { $0.id == open.id }
        // What the favorites are, for the wording under them: "trains" if they're all trains, "rides"
        // when it's a mix.
        let kinds = Set(cityFavorites.map(\.vehicle))
        let ride = kinds.count == 1 ? cityFavorites[0].vehicle : "ride"
        let rides = kinds.count == 1 ? cityFavorites[0].vehicles : "rides"
        // The map takes two thirds of the page. As a long list scrolls, the map shrinks with it,
        // then moves up into the header's room, so a favorite picked far down the list still shows on it.
        return ZStack(alignment: .top) {
            List {
                Section {
                    if cityFavorites.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Where do you wait?").font(.headline)
                            Text("Tap Add favorite, then your line where you get on, to start curating your suffering in \(city.name). Your stops land here and on your widgets. Tap one to put it on the map, then the map to watch the \(city.vehicles) not come, live.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    ForEach(cityFavorites) { favorite in
                        // Tapping a favorite opens it on the map above (tap that for the live map);
                        // hold and drag to reorder.
                        HStack(spacing: 8) {
                            if editingCity == city {
                                // Deletes at once: no Delete button to confirm with, it's only a favorite.
                                Button {
                                    withAnimation { favorites.removeAll { $0.id == favorite.id } }
                                    if !favorites.contains(where: { $0.city == city }) { editingCity = nil }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(.white, .red)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Delete \(favorite.lineLabel) to \(favorite.destination)")
                                .transition(.move(edge: .leading).combined(with: .opacity))
                            }
                            Button { select(favorite) } label: { favoriteRow(favorite) }
                            .buttonStyle(.borderless)
                            .tint(.primary)
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
                        // The row's own minus button deletes, not the list's: a sideways swipe on a row is
                        // for turning the page, and the list's minus would only reveal a Delete button.
                        .deleteDisabled(true)
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
                    // Under the tall map, until scrolled away.
                    .padding(.top, tallMap - Self.shortMap)
                } footer: {
                    // The Lock Screen button lives in the favorites' footer rather than a section of its
                    // own: a favorite dragged past the last row would otherwise land in that section,
                    // where it can't go, and snap back instead of moving to the end.
                    VStack(alignment: .leading, spacing: 10) {
                        if !cityFavorites.isEmpty {
                            Text("When you're in \(city.name), your widgets suffer in this order; the small ones only have room for the top one. Tap the map to watch the \(ride) not move, live. Hold and drag to reorder; Edit to delete.")
                        }
                        Button { showingGuide = true } label: {
                            Label("Put your \(cityFavorites.isEmpty ? city.vehicles : rides) on the Lock Screen", systemImage: "lock.iphone")
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
                        Text("Be let down without even unlocking your phone. Takes 30 seconds, less than any \(cityFavorites.isEmpty ? city.vehicle : ride).")
                    }
                    .textCase(nil)
                }
            }
            .environment(\.editMode, .constant(editingCity == city ? .active : .inactive))
            .refreshable { await feed.reload() }
            // The list starts below the hint, picker and map, and scrolls on under them. The safe area
            // only goes down to the short map, as rows under it don't take touches: the tall map's extra
            // room is space above the favorites, which shrinks the map as it scrolls away.
            // As safe area rather than a content margin, so the list knows that's where its visible top is:
            // a favorite dragged up there scrolls the list, instead of having to go up under the map.
            .safeAreaPadding(.top, headerHeight + Self.shortMap + 16)
            .modifier(ScrollOffset { scrollOffsets[city] = $0 })

            // The hint and city picker, then the map. Scrolling the list slides the hint and picker
            // up out of sight (and the map with them, into their room), in step with the finger.
            VStack(alignment: .leading, spacing: 0) {
                // The hint and city picker's room; they're drawn once, above the pages.
                Color.clear.frame(height: headerHeight)
                // The open favorite (with room at the top for its card, so the route isn't under it),
                // or before there is one, the city's main lines.
                // The map keeps its full height and is cut off at the top as it shrinks, so it slides
                // up with the list instead of being laid out again at every step of the scroll (which
                // stutters). Once the list is at rest, the route is framed in what's left.
                Color.clear
                    .frame(height: tallMap - shrink(city))
                    .overlay(alignment: .bottom) {
                        Group {
                            if openIsFavorite {
                                RouteMap(selection: open, feed: feed, interactive: false, topInset: 44,
                                         cropped: restingShrink[city] ?? 0)
                            } else {
                                CityLinesMap(city: city)
                            }
                        }
                        .frame(height: tallMap)
                        .allowsHitTesting(false)
                    }
                    .task(id: shrink(city)) {
                        let shrunk = shrink(city)
                        try? await Task.sleep(for: .milliseconds(250))
                        if !Task.isCancelled { restingShrink[city] = shrunk }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if openIsFavorite { openLiveMap() } }
                    .accessibilityAddTraits(openIsFavorite ? .isButton : [])
                    .accessibilityLabel(openIsFavorite ? "Live map, \(open.lineLabel) to \(open.destination)" : "\(city.name)'s main lines")
                    .overlay(alignment: .topLeading) {
                        if openIsFavorite {
                            openFavoriteCard(open)
                                .offset(y: pillNudge)
                                .task { await nudgePill() }
                                .padding(10)
                                // Clear of the share button.
                                .padding(.trailing, 48)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if openIsFavorite {
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
                    .modifier(ZoomSource(id: city, in: mapZoom))
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
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { pageHeight = $0 }
    }

    /// The city picker, above the city pages.
    private var cityHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("City", selection: Binding(get: { selection.city }, set: { switchCity(to: $0) })) {
                ForEach(City.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { headerHeight = $0 }
    }

    /// The map's height before the list scrolls: down to two thirds of the page.
    private var tallMap: CGFloat { max(Self.shortMap, (pageHeight * 2 / 3 - headerHeight).rounded()) }
    /// How small the map gets with the list scrolled.
    private static let shortMap: CGFloat = 260

    /// How much the map has shrunk for `city`: as far as its list is scrolled, down to the short map.
    private func shrink(_ city: City) -> CGFloat {
        min(max(scrollOffsets[city] ?? 0, 0), tallMap - Self.shortMap)
    }

    /// How far the header has slid away for `city`: as far as its list is scrolled past the map's
    /// shrinking, up to its height.
    private func collapse(_ city: City) -> CGFloat {
        min(max((scrollOffsets[city] ?? 0) - (tallMap - Self.shortMap), 0), headerHeight)
    }

    /// The favorite open on the map gets a thin frame in the line-badge red. It's only a marker.
    private func favoriteBackground(isSelected: Bool) -> some View {
        Color(.secondarySystemGroupedBackground)
            .overlay {
                if isSelected { SelectedFavoriteFrame() }
            }
    }

    /// The line and where it goes, with the next departure big on the right; the stop, with the two
    /// after it; and across the whole width, a comment on the wait. Each line shares its own width
    /// with its own times, so a wide "131 25 · 132 40" doesn't cut "To Downtown" short on the line
    /// above. Everything but the comment stays on its line and truncates instead of wrapping.
    private func favoriteRow(_ favorite: Selection) -> some View {
        TimelineView(.everyMinute) { context in
            let loaded = favoritesFeed.departures[favorite.id]
            let upcoming = (loaded ?? []).filter { $0.time > context.date.addingTimeInterval(-30) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    LineBadge(line: favorite.lineLabel, font: .system(.subheadline, design: .rounded).weight(.heavy))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .layoutPriority(1)
                    Text("To \(favorite.destination)").font(.subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                    Text(Departure.waits(upcoming, from: context.date, count: 1, lines: favorite.isMultiLine)
                         ?? (loaded == nil ? "…" : "none"))
                        .font(.system(.headline, design: .rounded).weight(.semibold))
                        .foregroundStyle(upcoming.first?.isLive == true ? .green : .secondary)
                        .monospacedDigit()
                        .fixedSize()
                }
                HStack(spacing: 8) {
                    Text(favorite.stopName).font(.footnote).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if let later = Departure.waits(Array(upcoming.dropFirst()), from: context.date, count: 2, unit: false, lines: favorite.isMultiLine) {
                        Text(later)
                            .font(.system(.caption, design: .rounded).weight(.medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize()
                    }
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
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
    }

    /// The open favorite, in one line over the top of the map: line, stop and the next departure, as
    /// the Dynamic Island would show it. Tapping it puts it up there (or on the Lock Screen, without an
    /// island), or takes it off again; tapping the rest of the map opens the live map.
    private func openFavoriteCard(_ open: Selection) -> some View {
        let (departures, dimmed) = shownDepartures(for: open)
        let canWatch = BusActivities.shared.isAvailable
        let watching = BusActivities.shared.isWatching(open)
        return Button {
            if canWatch {
                BusActivities.shared.toggle(open, departures: departures,
                                            fetchedAt: open.id == selection.id ? feed.refresh?.fetchedAt ?? .now : .now)
            } else {
                openLiveMap()
            }
        } label: {
            TimelineView(.everyMinute) { context in
                let next = departures.first { $0.time > context.date.addingTimeInterval(-30) }
                let showsTime = open.id != selection.id || feed.error == nil
                // Up on the island, it leaves its outline here, still saying what's up there.
                IslandPill(line: open.lineLabel, next: showsTime ? next : nil, middle: open.stopName, dimmed: dimmed, lifted: watching)
                    .frame(height: 34)
            }
        }
        .buttonStyle(.plain)
        .popoverTip(StalkTip(island: Island.frame != nil), arrowEdge: .top)
        .accessibilityLabel("\(open.lineLabel) at \(open.stopName)")
        .accessibilityHint(!canWatch ? "Opens the live map"
                           : watching ? "Stops watching it from \(Island.frame != nil ? "the Dynamic Island" : "the Lock Screen")"
                           : "Watches it from \(Island.frame != nil ? "the Dynamic Island" : "the Lock Screen")")
    }

    /// Hops the pill up toward the island and back, once ever, a moment after it first shows: a hint
    /// that it goes up there. The tip under it says so in words.
    private func nudgePill() async {
        guard !pillNudged, !reduceMotion, BusActivities.shared.isAvailable, Island.frame != nil else { return }
        try? await Task.sleep(for: .seconds(1.2))
        guard !Task.isCancelled else { return }
        pillNudged = true
        for _ in 0..<2 {
            withAnimation(.spring(duration: 0.25, bounce: 0.2)) { pillNudge = -7 }
            try? await Task.sleep(for: .milliseconds(220))
            withAnimation(.spring(duration: 0.45, bounce: 0.55)) { pillNudge = 0 }
            try? await Task.sleep(for: .milliseconds(450))
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

    /// Opens the line a widget row showed on its live map, over whatever was on screen. Back from
    /// the map, it stays the open stop: it's the one you came for.
    private func openFromWidget(_ tapped: Selection) {
        choosing = false
        sharing = nil
        editingCity = nil
        select(tapped)
        showingMap = true
    }

    private func takeWidgetTap() {
        if let tapped = WidgetTap.take() { openFromWidget(tapped) }
    }

    /// Blows the home map up into the live map.
    private func openLiveMap() {
        editingCity = nil
        showingMap = true
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
/// The live map and the line picker grow out of the home map and shrink back into it (iOS 18; before,
/// they slide in as usual).
private struct ZoomTransition: ViewModifier {
    let id: City
    let namespace: Namespace.ID

    init(id: City, in namespace: Namespace.ID) {
        self.id = id
        self.namespace = namespace
    }

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}

/// The home map a city's live map zooms out of and back into.
private struct ZoomSource: ViewModifier {
    let id: City
    let namespace: Namespace.ID

    init(id: City, in namespace: Namespace.ID) {
        self.id = id
        self.namespace = namespace
    }

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.matchedTransitionSource(id: id, in: namespace) {
                $0.clipShape(RoundedRectangle(cornerRadius: ListCorners.radius, style: .continuous))
            }
        } else {
            content
        }
    }
}

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

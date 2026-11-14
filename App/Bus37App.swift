import MapKit
import SwiftUI
import TipKit
import WidgetKit

@main
struct Bus37App: App {
    /// The widget walkthrough and the map of cities, before the home screen: on the first launch, and
    /// once for those who updated from before there were cities to pick.
    @State private var welcoming = Welcome.isNeeded

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
        #if DEBUG
        // `-reorderTip YES`: as just after a city's second favorite, with the pill's tip out of the way.
        if UserDefaults.standard.bool(forKey: "reorderTip") {
            ReorderTip.hasTwo = true
            StalkTip.hasLetGo = true
        }
        #endif
        SystemDiagnostics.shared.start()
    }

    private var home: some View {
        Group {
            if welcoming {
                Welcome {
                    WidgetGuide.hasBeenShown = true
                    withAnimation { welcoming = false }
                }
            } else {
                // Over everything, where the island is: it opens out there when handed a watch.
                ContentView().overlay { IslandShowOffView() }
            }
        }
        .journeySessions()
        // The map of cities' pictures, made in the background from the start, so it opens with them.
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { CityPictures.shared.prepare(forScreen: $0) }
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let screen = ScreenshotScreen.current, [.widgets, .mapwidgets, .lock, .lockwidget].contains(screen) {
                WidgetShowcase(screen: screen)
            } else {
                home
            }
            #else
            home
            #endif
        }
    }
}


/// The home screen, as reels: each favorite a map over the whole screen, swiped up and down, a city's
/// favorites one after another with the stop picker after the last. Swiped sideways, the next city's;
/// past the last city, the map of cities to choose them. Holding a map zooms out to all of the city's,
/// to move it about, or drop it on the bin.
struct ContentView: View {
    @State private var selection = Selection.current
    @State private var feed = DepartureFeed()
    @State private var favoritesFeed = FavoritesFeed()
    @Environment(\.scenePhase) private var scenePhase
    /// The lines by number or name, from the picker's side, for those who know theirs.
    @State private var searchingLines = false
    @State private var pickerPath: [Line] = []
    /// The stop being shared.
    @State private var sharing: Selection?
    /// Where the share was opened, for Journey.
    @State private var sharingFrom = "map"
    /// A stop from a shared link, waiting for "Add".
    @State private var incoming: Selection?
    /// Who shared the incoming stop (see Selection.sharer), for Journey.
    @State private var sharedBy: String?
    @State private var favorites = Selection.favorites
    /// Commutes, each a page ahead of its city's favorites (see Trips.swift), and the one being set up.
    @State private var trips = Trip.enabled ? Trip.all : []
    @State private var editingTrip: Trip?
    /// The widget walkthrough, from the picker's side (and screenshot runs).
    @State private var showingGuide = false
    /// The cities shown, with a page each (see `City.chosen`).
    @State private var cities = City.chosen
    /// The page showing across: a city's (by its raw value), or the cities past the last (`citiesPage`).
    @State private var page: String? = Selection.current.city.rawValue
    /// The page showing in each city, up and down: a favorite's id, or the picker (`pickerPage`).
    @State private var reels: [City: String] = [:]
    /// Each city's picker, made afresh once a stop has been picked from it.
    @State private var pickerRounds: [City: Int] = [:]
    /// Two fingers moving a map, as they go, and which page's map (see `MapTouches`).
    @State private var mapGesture: (page: String, gesture: MapGesture)?
    /// Where the buttons along the side of a city's picker are.
    @State private var pickerRails: [City: CGRect] = [:]
    /// Where what lies over each city's pages is (the title, the favorites down the side), whose taps
    /// aren't the picker's either.
    @State private var overMaps: [String: CGRect] = [:]
    /// How far each city's pages are swiped, in pages (1.5: halfway from its second favorite to its third),
    /// for the ring down the side to follow.
    @State private var reelProgress: [City: CGFloat] = [:]
    /// A stop picked in each city's top page, open there for now: not a favorite until it's added.
    @State private var browsing: [City: Selection] = [:]
    /// The city whose picker the + below the favorites opened: a stop picked there is added straight away.
    @State private var addingIn: City?
    /// The favorite being changed, in the stop picker over its page (the pencil above sharing).
    @State private var editing: Selection?
    /// A favorite held down the side, being moved among the others there, and where each circle is.
    @State private var sideDrag: SideDrag?
    @State private var storyFrames: [String: CGRect] = [:]
    /// Where the + below each city's favorites is, and their column's scrolling content, in the window: the
    /// + is a bin while one's moved, and the finger moving it is in the column's own space.
    @State private var sideBins: [City: CGRect] = [:]
    @State private var columnOrigins: [City: CGPoint] = [:]
    /// Bumped to have a city's pages jump to the page showing, where it's moved to (its id stays the same, so
    /// setting it again wouldn't move them).
    @State private var pageJumps: [City: Int] = [:]
    /// The favorite moved down the side is over the bin.
    @State private var overSideBin = false
    /// How far the cities' pages are swiped, in pages, for the ring along the cities to follow.
    @State private var cityProgress: CGFloat?
    /// Where the city switch under way came from, for Journey, when not a swipe (a dot).
    @State private var switchingFrom: String?
    /// Whether the cities' dots show: for a few seconds after the app opens or the cities are swiped,
    /// then they fade. Each swipe starts the wait again.
    @State private var dotsAwake = true
    @State private var dotsWoken = 0
    /// A finger on the dots, sliding along them from city to city, as along the Home Screen's page dots.
    @State private var scrubbingDots = false
    /// When a finger came down on the dots, and the page then.
    @State private var dotsTouch: (at: Date, page: String?)?
    /// The screen's height, for the favorites' share of it.
    @State private var screenHeight: CGFloat = 0
    /// A city's favorites zoomed out to move about, after holding one.
    @State private var reordering: Reordering?
    /// Where each zoomed-out favorite is, and the bin, in the window.
    @State private var cellFrames: [String: CGRect] = [:]
    /// The size of the zoomed-out favorites' screen, to place the held one in it.
    @State private var gridScreen: CGSize = .zero
    @State private var binFrame: CGRect = .null
    /// The screen's safe area: the pages go under it, what's over them stays clear of it.
    @State private var insets = EdgeInsets()
    /// The pill hopping toward the island, the first time it's there: it goes up there.
    @State private var pillNudge: CGFloat = 0
    @AppStorage("pillNudged") private var pillNudged = false
    /// The dots have been slid along once: the hint about them, on an empty city's picker, is no longer needed.
    @AppStorage("dotsScrubbed") private var dotsScrubbed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private static let citiesPage = "cities"
    private static let pickerPage = "picker"
    /// What lies over the bottom of a favorite's map: its caption and Apple's logo below it.
    private static let captionRoom: CGFloat = 150
    /// The room under the caption for the Apple Maps logo and Legal link, and the cities' dots beside them.
    private static let logoRoom: CGFloat = 46

    private var departures: [Departure] { feed.departures }
    private var loaded: Selection? { feed.loaded }
    private var isStale: Bool { loaded?.id != selection.id }

    var body: some View {
        GeometryReader { geometry in
            pages
                .ignoresSafeArea()
                .overlay(alignment: .bottom) { cityDots }
                .onAppear { insets = geometry.safeAreaInsets; screenHeight = geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom }
                .onChange(of: geometry.safeAreaInsets) { insets = geometry.safeAreaInsets }
                .onChange(of: geometry.size.height) { screenHeight = geometry.size.height + insets.top + insets.bottom }
        }
        .background(.black)
        .overlay {
            if let reordering {
                grid(reordering)
                    .transition(.opacity.combined(with: .scale(scale: 1.4)))
            }
        }
        .journeyScreen("home")
        .onAppear { Journey.shared.setCity(selection.city.rawValue) }
        // Only the times of a favorite, or of a stop open for now on the top page, are followed live.
        .task(id: followsLive(selection) ? selection : nil) {
            if followsLive(selection) { await feed.follow(selection) }
        }
        .task(id: favorites) { await favoritesFeed.follow(favorites) }
        .task { await startInNearestCity() }
        // How far each city's maps zoom out, worked out in the background before its page is swiped to.
        .task(id: cities) { City.prepareNetwork(for: shownCities) }
        // Counts the visits with a favorite, for when to point out its pill.
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
        .onChange(of: selection.city) { if page != selection.city.rawValue { page = selection.city.rawValue } }
        .onOpenURL { url in
            // A widget tap: that line and stop.
            if let tapped = Selection(openURL: url) { return openFromWidget(tapped, on: url.tappedOn) }
            // A friend's stop, from a 37shadesoflate.com/s link (or its QR code), with who shared it.
            sharedBy = Selection.sharer(of: url)
            Journey.shared.tap("link.open", sharedBy)
            Task { incoming = await Selection.shared(by: url) }
        }
        .alert(incoming.map { "Add the \($0.spokenLines) at \($0.stopName)?" } ?? "",
               isPresented: Binding(get: { incoming != nil }, set: { if !$0 { incoming = nil } })) {
            Button("Add to favorites") {
                Journey.shared.tap("link.add", sharedBy)
                if let picked = incoming {
                    // A friend's stop in a city left out brings the city back.
                    if !cities.contains(picked.city) { setCities(cities + [picked.city]) }
                    if !favorites.contains(where: { $0.id == picked.id }) {
                        favorites.append(picked)
                        Journey.shared.tap("favorite.added", Journey.from("link"))
                    }
                    Journey.shared.tap("stop.open", Journey.from("link"))
                    show(picked)
                }
            }
            Button("Not now", role: .cancel) { Journey.shared.tap("link.dismiss", sharedBy) }
        } message: {
            if let incoming { Text("To \(incoming.destination), in \(incoming.city.endingSentence) It joins your favorites there.") }
        }
        // The map widget's pictures of each favorite, drawn here: the widget hasn't the memory to.
        .task { WidgetMapPainter.paint(favorites) }
        .onChange(of: trips) { if Trip.enabled { Trip.all = trips } }
        .sheet(item: $editingTrip) { trip in
            TripEditor(trip: trip, stops: favorites.filter { $0.city == trip.city }) { saved in
                if let index = trips.firstIndex(where: { $0.id == saved.id }) { trips[index] = saved } else { trips.append(saved) }
                Journey.shared.tap("trip.saved", "\(saved.toHome.count + saved.toWork.count) ways")
                go(to: Self.tripPage(saved), in: saved.city)
            } onDelete: {
                Journey.shared.tap("trip.delete")
                trips.removeAll { $0.id == trip.id }
            }
        }
        .onChange(of: favorites) {
            Selection.favorites = favorites
            // A city's second favorite: they can be put in order now.
            if Dictionary(grouping: favorites, by: \.city).values.contains(where: { $0.count >= 2 }) { ReorderTip.hasTwo = true }
            WidgetMapPainter.paint(favorites)
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
                Task { try? await Task.sleep(for: .seconds(1.5)); sharingFrom = "map"; sharing = selection }
            case .lines: reels[selection.city] = Self.pickerPage
            case .cities: page = Self.citiesPage
            case .stops:
                reels[selection.city] = Self.pickerPage
                searchingLines = true
                // After the sheet is up: pushed in the same moment, the title draws twice.
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    pickerPath = [Line(id: selection.lineID, name: selection.lineName, mode: "bus")]
                }
            default: break
            }
        }
        #endif
        .sheet(item: $sharing) { stop in
            ShareSheet(selection: stop, departures: shownDepartures(for: stop).departures, from: sharingFrom)
        }
        .sheet(isPresented: $searchingLines, onDismiss: { pickerPath = [] }) {
            NavigationStack(path: $pickerPath) {
                LinePicker { stop in if let editing { edited(editing, to: stop) } else { picked(stop) } }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { searchingLines = false } }
                    }
            }
        }
        .fullScreenCover(isPresented: $showingGuide) {
            WidgetGuide { showingGuide = false }
        }
    }

    // MARK: - Pages

    /// Along the bottom, staying put as the cities' pages slide under it: a dot per city, growing as its
    /// page comes in, then the map of cities' +, and beside them the city's name, fading into the next.
    private var cityDots: some View {
        let cities = shownCities
        let at = cityProgress ?? CGFloat(cities.firstIndex(of: selection.city) ?? 0)
        let near = min(max(Int(at.rounded()), 0), cities.count)
        let name = near < cities.count ? cities[near].name : "Your cities"
        return HStack(spacing: 10) {
            HStack(spacing: Self.dotSpacing) {
                ForEach(Array(cities.enumerated()), id: \.element) { index, city in
                    let close = max(0, 1 - abs(CGFloat(index) - at))
                    Circle()
                        .fill(.white.opacity(0.45 + 0.55 * close))
                        .frame(width: 6 + 4 * close, height: 6 + 4 * close)
                        .frame(width: Self.dotWidth, height: 22)
                        .accessibilityElement()
                        .accessibilityLabel(city.name)
                        .accessibilityAction { scrubDots(to: index) }
                        .accessibilityAddTraits(index == near ? [.isButton, .isSelected] : .isButton)
                }
                let close = max(0, 1 - abs(CGFloat(cities.count) - at))
                Image(systemName: "plus")
                    .font(.system(size: 8 + 3 * close, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.45 + 0.55 * close))
                    .frame(width: Self.dotWidth, height: 22)
                    .accessibilityElement()
                    .accessibilityLabel("Choose cities")
                    .accessibilityAction { scrubDots(to: cities.count) }
                    .accessibilityAddTraits(.isButton)
            }
            Text(name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .id(name)
                .transition(.opacity)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        // The way across where the pages don't swipe, over a city's stop picker. Held and slid along, the dots
        // grow and go from city to city under the finger; swiped (dots or name), one city over, as the pages
        // go; tapped, the city of the dot.
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { drag in
                let start = dotsTouch ?? (drag.time, page)
                if dotsTouch == nil { dotsTouch = start }
                // Kept up (and touchable) while the finger's on them, whatever page it slides to.
                wakeDots()
                // A quick swipe isn't a slide along them: only once the finger's been down a moment.
                guard scrubbingDots || drag.time.timeIntervalSince(start.at) > Self.holdToScrub else { return }
                if !scrubbingDots {
                    dotsScrubbed = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.snappy(duration: 0.2)) { scrubbingDots = true }
                }
                scrubDots(to: Int(drag.location.x / (Self.dotWidth + Self.dotSpacing)))
            }
            .onEnded { drag in
                defer {
                    dotsTouch = nil
                    withAnimation(.snappy(duration: 0.25)) { scrubbingDots = false }
                    wakeDots()
                }
                guard !scrubbingDots else { return }
                let across = drag.predictedEndTranslation.width
                if abs(across) > 30 || abs(drag.translation.width) > 20 {
                    // Right to left, the next city, as a page swiped that way.
                    dotsScrubbed = true
                    let cities = shownCities
                    let now = cities.firstIndex { $0.rawValue == page } ?? (page == Self.citiesPage ? cities.count : 0)
                    scrubDots(to: now + (across < 0 ? 1 : -1))
                } else if drag.location.x < CGFloat(shownCities.count + 1) * (Self.dotWidth + Self.dotSpacing) {
                    scrubDots(to: Int(drag.location.x / (Self.dotWidth + Self.dotSpacing)))
                }
            })
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .glass(in: Capsule())
        .scaleEffect(scrubbingDots ? 1.5 : 1, anchor: .bottom)
        // The name fading into the next, and the bubble growing or shrinking to it.
        .animation(.smooth(duration: 0.3), value: name)
        .environment(\.colorScheme, .dark)
        // On the line of Apple's logo, under the caption, clear of the home indicator.
        .padding(.bottom, max(insets.bottom - 22, 6))
        // Kept up over the picker, whose map takes the swipe across: tapped, the way to another city.
        .opacity(reordering == nil && editing == nil && (dotsAwake || scrubbingDots || onPicker(cityShown)) ? 1 : 0)
        .allowsHitTesting(dotsAwake || scrubbingDots || onPicker(cityShown))
        .task(id: dotsWoken) {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.6)) { dotsAwake = false }
        }
    }

    /// The city whose pages are on screen (not the open stop's, until one's opened there).
    private var cityShown: City { page.flatMap(City.init(rawValue:)) ?? selection.city }

    /// Held this long, a finger on the dots slides along them; quicker, it's a swipe or a tap.
    private static let holdToScrub = 0.18
    private static let dotWidth: CGFloat = 12
    private static let dotSpacing: CGFloat = 7

    /// To the city at `index` along the dots (past the last, the map of cities), as the finger slides over it.
    private func scrubDots(to index: Int) {
        let cities = shownCities
        let index = min(max(index, 0), cities.count)
        let target = index < cities.count ? cities[index].rawValue : Self.citiesPage
        guard target != page else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        if target == Self.citiesPage { Journey.shared.tap("cities.edit", "dots") }
        switchingFrom = "dots"
        withAnimation(.smooth(duration: 0.3)) { page = target }
    }

    /// The dots back, for another few seconds.
    private func wakeDots() {
        if !dotsAwake { withAnimation(.easeInOut(duration: 0.2)) { dotsAwake = true } }
        dotsWoken += 1
    }

    /// The cities side by side, a page each, and the map of cities past the last. A swipe moves one
    /// page and no further, as reels do.
    private var pages: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(shownCities) { city in
                    cityPage(city)
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(city.rawValue)
                }
                CityChooser(onCancel: backFromCities) {
                    setCities(City.chosen)
                    backFromCities()
                }
                // Clear of the status bar and the home indicator, the pages going under them.
                .padding(.top, insets.top)
                .padding(.bottom, insets.bottom)
                .background(Color(.systemBackground).environment(\.colorScheme, .dark))
                .containerRelativeFrame([.horizontal, .vertical])
                .id(Self.citiesPage)
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $page)
        .scrollIndicators(.hidden)
        .modifier(PageProgress(axis: .horizontal) { progress in
            // Moved sideways (not just made): the dots come back.
            if let old = cityProgress, abs(old - progress) > 0.001 { wakeDots() }
            cityProgress = progress
        })
        .scrollDisabled(reordering != nil || editing != nil || City(rawValue: page ?? "").map(onPicker) == true)
        .onChange(of: page) { old, new in
            // What's in front for Journey: the map of cities, or a city's picker, come and gone with its page.
            if old == Self.citiesPage { Journey.shared.hide("cities") }
            if let left = old.flatMap(City.init(rawValue:)), reels[left] == Self.pickerPage { Journey.shared.hide("picker.map") }
            if new == Self.citiesPage { Journey.shared.show("cities", detail: "edit") }
            if let city = new.flatMap(City.init(rawValue:)), reel(in: city).wrappedValue == Self.pickerPage { Journey.shared.show("picker.map") }
            if let city = new.flatMap(City.init(rawValue:)) { switchCity(to: city, from: switchingFrom ?? "swipe") }
            else if new == Self.citiesPage, switchingFrom == nil { Journey.shared.tap("cities.edit", "swipe") }
            switchingFrom = nil
        }
        // The favorites zoomed out, as a screen of their own.
        .onChange(of: reordering == nil) { _, closed in
            if closed { Journey.shared.hide("favorites.grid") } else { Journey.shared.show("favorites.grid") }
        }
    }

    /// One city: the stop picker on top, then its favorites one under another, a screen each. The maps
    /// next to the one showing are made ahead, so they've framed their route by the time they slide in;
    /// those further away are left out until then.
    private func cityPage(_ city: City) -> some View {
        let cityFavorites = favorites.filter { $0.city == city }
        let shown = reel(in: city).wrappedValue
        let tripCount = trips.filter { $0.city == city }.count
        let at = Int(pageIndex(of: shown, in: city))
        // Where the pages actually are, which a page view just made may not have scrolled to yet.
        let showing = reelProgress[city].map { Int($0.rounded()) }
        let near = { (page: Int) in abs(page - at) <= 1 || showing.map({ abs(page - $0) <= 1 }) == true }
        let cityTrips = trips.filter { $0.city == city }
        return ScrollViewReader { scroller in
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                Group {
                    if !near(0) {
                        Color.black
                    } else if let stop = browsing[city] {
                        reel(stop, browsed: true).transition(.opacity)
                    } else {
                        pickerReel(city, first: cityFavorites.isEmpty).transition(.opacity)
                    }
                }
                .containerRelativeFrame([.horizontal, .vertical])
                .id(Self.pickerPage)
                ForEach(cityTrips) { trip in
                    TripPage(trip: trip, topInset: routeTop(city), bottomInset: insets.bottom, leadingInset: routeLeading(city)) {
                        Journey.shared.tap("trip.edit")
                        editingTrip = trip
                    }
                    .containerRelativeFrame([.horizontal, .vertical])
                    .id(Self.tripPage(trip))
                }
                ForEach(Array(cityFavorites.enumerated()), id: \.element.id) { index, favorite in
                    Group {
                        if near(1 + tripCount + index) { reel(favorite) } else { Color.black }
                    }
                    .containerRelativeFrame([.horizontal, .vertical])
                    .id(favorite.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: reel(in: city))
        .scrollIndicators(.hidden)
        .scrollDisabled(reordering != nil || editing != nil || onPicker(city))
        .modifier(PageProgress { reelProgress[city] = $0 })
        .onChange(of: pageJumps[city]) {
            guard let shown = reel(in: city).wrappedValue else { return }
            scroller.scrollTo(shown, anchor: .top)
        }
        // Made, a page view starts at its top whatever its position says: to the one it's to show.
        .onAppear {
            guard let shown else { return }
            // Once it's laid out: before, there's nowhere to scroll to.
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                scroller.scrollTo(shown, anchor: .top)
            }
        }
        }
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 10) {
                header(city)
                side(city)
            }
            .padding(.top, insets.top + 2)
        }
        .overlay(alignment: .topTrailing) { helpButton(city) }
    }

    /// Which page `city` shows: the one it was left on, else the open stop or the favorite switching there
    /// opens, else its picker. Swiping to a favorite makes it the open stop.
    private func reel(in city: City) -> Binding<String?> {
        Binding {
            if let shown = reels[city], shown == Self.pickerPage || favorites.contains(where: { $0.id == shown })
                || trips.contains(where: { $0.city == city && Self.tripPage($0) == shown }) { return shown }
            // The open stop, where it's this city's; else the one switching here opens.
            let opening = city == selection.city && isFavorite(selection) ? selection : opening(city)
            return favorites.contains { $0.id == opening.id } ? opening.id : Self.pickerPage
        } set: { new in
            guard let new else { return }
            let old = reels[city]
            reels[city] = new
            if new == Self.pickerPage, old != Self.pickerPage { Journey.shared.show("picker.map") }
            if old == Self.pickerPage, new != Self.pickerPage {
                Journey.shared.hide("picker.map")
                if addingIn == city { addingIn = nil }
            }
            let stop = new == Self.pickerPage ? browsing[city] : favorites.first(where: { $0.id == new })
            guard city == selection.city, let stop, stop.id != selection.id else { return }
            Journey.shared.tap("stop.open", Journey.from("swipe"))
            select(stop)
        }
    }

    /// A trip's page, by its id.
    static func tripPage(_ trip: Trip) -> String { "trip:\(trip.id)" }

    /// Whether `city` shows its stop picker's map, which takes one finger itself: the pages, up and down and
    /// across to the other cities, stand still under it.
    private func onPicker(_ city: City) -> Bool {
        reel(in: city).wrappedValue == Self.pickerPage && browsing[city] == nil
    }

    /// Where `page` is in `city`'s pages, top first: the picker, the trips, then the favorites.
    private func pageIndex(of page: String?, in city: City) -> CGFloat {
        if page == Self.pickerPage { return 0 }
        let cityTrips = trips.filter { $0.city == city }
        if let trip = cityTrips.firstIndex(where: { Self.tripPage($0) == page }) { return CGFloat(1 + trip) }
        return CGFloat(1 + cityTrips.count + (favorites.filter { $0.city == city }.firstIndex { $0.id == page } ?? 0))
    }

    /// The app's name over the top of the pages, as the icon has it.
    private func header(_ city: City) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("37")
                    .font(.system(.title3, design: .rounded).weight(.heavy))
                    .padding(.horizontal, 5)
                    .background(LineBadge.red, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text("Shades of Late")
                    .font(.title3.weight(.bold))
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.55), radius: 4, y: 1)
            .padding(.leading, 4)
        }
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { overMaps["\(city.rawValue) header"] = $0 }
    }

    /// Where the picker's buttons for the kinds of lines go: just under the ?.
    static func kindsTop(_ insets: EdgeInsets) -> CGFloat { insets.top + 44 }

    /// The ?, across from the title: how to put the stops on the Lock Screen, and watch one from the island.
    private func helpButton(_ city: City) -> some View {
        Button {
            Journey.shared.tap("guide.open", Journey.from("help"))
            showingGuide = true
        } label: {
            Image(systemName: "questionmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .glass(in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .environment(\.colorScheme, .dark)
        .accessibilityLabel("How it works")
        .padding(.trailing, 10)
        .padding(.top, insets.top - 6)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { overMaps["\(city.rawValue) help"] = $0 }
    }

    /// Down the left, as stories are: the stop picker, then the city's favorites, to jump to, in up to a
    /// share of the screen (a slice of the next saying there are more, the rest a scroll away). Changing one
    /// (the pencil), they fold away and an ✕ leaves it as it was.
    @ViewBuilder private func side(_ city: City) -> some View {
        let cityFavorites = favorites.filter { $0.city == city }
        if !cityFavorites.isEmpty || trips.contains(where: { $0.city == city }) {
            VStack(spacing: 10) {
                // While one's moved, in the order it's being moved into.
                let shown = sideDrag?.city == city
                    ? sideDrag!.order.compactMap { id in cityFavorites.first { $0.id == id } } : cityFavorites
                let changing = editing?.city == city
                // Changing one, the others fold away up under the title, the ✕ taking their place.
                favoritesColumn(shown, shown: reel(in: city).wrappedValue, in: city)
                    .modifier(ReorderTipAnchor(shows: !changing && cityFavorites.count >= 2 && city == cityShown))
                    .scaleEffect(x: 1, y: changing ? 0.01 : 1, anchor: .top)
                    .opacity(changing ? 0 : 1)
                    .frame(height: changing ? 0 : nil, alignment: .top)
                    .allowsHitTesting(!changing)
                // The + adds a favorite: the picker on top, the stop picked there joining the favorites (an ✕
                // while it's open, to leave it); changing one, the ✕ leaves it as it was.
                // Moving one, the + is a bin to drop it on.
                let binning = sideDrag?.city == city
                sideCircle {
                    Image(systemName: binning ? "trash" : addingIn == city || changing ? "xmark" : "plus")
                        .font(.system(size: 20, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                } action: {
                    if changing { stopEditing(saved: false) } else { toggleAdding(in: city) }
                }
                .background(Circle().fill(LineBadge.red).opacity(binning && overSideBin ? 1 : 0))
                .scaleEffect(binning && overSideBin ? 1.15 : 1)
                .animation(.snappy(duration: 0.2), value: overSideBin)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { sideBins[city] = $0 }
                .accessibilityLabel(changing ? "Leave it as it was" : addingIn == city ? "Stop adding a favorite" : "Add a favorite")
            }
            .padding(.leading, 12)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { overMaps["\(city.rawValue) side"] = $0 }
        }
    }

    /// The pencil: the favorite open in the stop picker, over its page, to change its stop, way or lines.
    private func startEditing(_ favorite: Selection) {
        Journey.shared.tap("favorite.edit")
        withAnimation(.smooth(duration: 0.45)) { editing = favorite }
    }

    /// Back to the favorite, changed or (the ✕) as it was.
    private func stopEditing(saved: Bool) {
        if !saved { Journey.shared.tap("favorite.edit.cancel") }
        withAnimation(.smooth(duration: 0.45)) { editing = nil }
    }

    /// A stop kept in the picker while changing `old`: it takes the favorite's place, where it was in their
    /// order (or, already a favorite itself, the old one just goes).
    private func edited(_ old: Selection, to new: Selection) {
        searchingLines = false
        guard new.id != old.id else { return stopEditing(saved: true) }
        Journey.shared.tap("favorite.edited")
        if favorites.contains(where: { $0.id == new.id }) {
            favorites.removeAll { $0.id == old.id }
        } else if let index = favorites.firstIndex(where: { $0.id == old.id }) {
            favorites[index] = new
        }
        // Watching the old one on the island, the new one instead.
        if BusActivities.shared.isWatching(old) { BusActivities.shared.toggle(old, departures: [], fetchedAt: .now) }
        reels[new.city] = new.id
        select(new)
        stopEditing(saved: true)
    }

    /// A round button down the side, dark glass as the favorites' column is.
    private func sideCircle(@ViewBuilder _ label: () -> some View, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label()
                .foregroundStyle(.white)
                .frame(width: Self.sideWidth, height: Self.sideWidth)
                .glass(in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .environment(\.colorScheme, .dark)
    }

    private static let sideWidth: CGFloat = 52
    /// A favorite's circle down the side, and the room between them.
    private static let storySize: CGFloat = 44
    private static let storyGap: CGFloat = 8
    /// How much of the screen's height the favorites may take, at most.
    private static let sideShare: CGFloat = 0.45

    /// The favorites column's scrolling content, where its circles are and a finger moving one is.
    static let columnSpace = "favorites column"

    /// How much bigger the circle showing is than the others, standing out past the column's edges.
    private static let shownScale: CGFloat = 0.28
    /// How far (in circles) the magnifying reaches either side of the one showing, as along the Mac's Dock.
    private static let dockReach: CGFloat = 1.6

    /// Where the ring down the side is, in circles (the picker's first): following the pages as they're
    /// swiped (from iOS 18), else on the one showing.
    private func progress(in city: City, shown: String?) -> CGFloat {
        if let swiped = reelProgress[city] { return max(swiped, 0) }
        return pageIndex(of: shown, in: city)
    }

    /// How big the circle at `index` is, as on the Mac's Dock: the one showing biggest, its neighbours a little
    /// bigger too, all of it moving along as the pages are swiped. Not while one's being moved.
    private func storyScale(_ index: Int, at: CGFloat) -> CGFloat {
        guard sideDrag == nil else { return 1 }
        let near = max(0, 1 - pow(abs(CGFloat(index) - at) / Self.dockReach, 2))
        return 1 + Self.shownScale * near
    }

    /// A circle in the column at its size, taking up its room so the others make way, as on the Dock.
    private func docked(_ story: some View, _ index: Int, at: CGFloat) -> some View {
        let scale = storyScale(index, at: at)
        return story
            .scaleEffect(scale)
            .frame(width: Self.storySize * scale, height: Self.storySize * scale)
    }

    /// The middle of the circle at `index`, from the top of the column, with every circle at its size.
    private func storyCenter(_ index: Int, at: CGFloat) -> CGFloat {
        var y = Self.storyGap
        for before in 0..<index { y += Self.storySize * storyScale(before, at: at) + Self.storyGap }
        return y + Self.storySize * storyScale(index, at: at) / 2
    }

    /// The city's favorites, a circle each, the one showing ringed and magnified. As many as fit in their
    /// share of the screen; past that, a slice of the next shows, and the column scrolls.
    private func favoritesColumn(_ cityFavorites: [Selection], shown: String?, in city: City) -> some View {
        let step = Self.storySize + Self.storyGap
        let room = max(screenHeight * Self.sideShare, step)
        let fit = max(Int((room - Self.storyGap) / step), 1)
        // The picker, the trips, then the favorites: a circle each.
        let cityTrips = trips.filter { $0.city == city }
        let count = 1 + cityTrips.count + cityFavorites.count
        let at = progress(in: city, shown: shown)
        // Room for the magnified ones too: the one showing and its neighbours, at most.
        let magnified = Self.storySize * Self.shownScale * (1 + 2 * (1 - pow(1 / Self.dockReach, 2)))
        let height = count <= fit
            ? CGFloat(count) * step + Self.storyGap + magnified
            : CGFloat(fit) * step + Self.storyGap + Self.storySize * 0.4
        return ScrollViewReader { scroller in
            ScrollView(.vertical) {
                VStack(spacing: Self.storyGap) {
                    docked(pickerStory(in: city), 0, at: at)
                    ForEach(Array(cityTrips.enumerated()), id: \.element.id) { index, trip in
                        docked(TripStory(home: Trip.homeByDefault)
                            .frame(width: Self.storySize, height: Self.storySize)
                            .contentShape(Circle())
                            .onTapGesture { go(to: Self.tripPage(trip), in: city) }
                            .accessibilityElement(children: .ignore)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel("Trip \(Trip.homeByDefault ? "home" : "to work")"), 1 + index, at: at)
                            .id(Self.tripPage(trip))
                    }
                    ForEach(Array(cityFavorites.enumerated()), id: \.element.id) { index, favorite in
                        docked(story(favorite, in: city), 1 + cityTrips.count + index, at: at)
                            // The held one under the finger: its slot and its offset change together, unanimated, so
                            // it stays put as the others slide round it.
                            .offset(y: heldOffset(favorite.id, slot: 1 + cityTrips.count + index, in: city))
                            .animation(sideDrag?.held == favorite.id ? nil : .snappy(duration: 0.25), value: sideDrag?.order)
                            .id(favorite.id)
                    }
                }
                .padding(.vertical, Self.storyGap)
                .coordinateSpace(.named(Self.columnSpace))
                .onGeometryChange(for: CGPoint.self, of: { $0.frame(in: .global).origin }) { columnOrigins[city] = $0 }
                // The ring over the one showing, sliding from circle to circle as the pages are swiped.
                .overlay(alignment: .top) {
                    let ringAt = min(at, CGFloat(count - 1))
                    let below = Int(ringAt.rounded(.down)), above = min(below + 1, count - 1)
                    let between = ringAt - CGFloat(below)
                    let size = Self.storySize * ((1 - between) * storyScale(below, at: at) + between * storyScale(above, at: at))
                    let center = (1 - between) * storyCenter(below, at: at) + between * storyCenter(above, at: at)
                    Circle()
                        .strokeBorder(LineBadge.red, lineWidth: 3)
                        .frame(width: size, height: size)
                        .offset(y: center - size / 2)
                        .opacity(sideDrag?.city == city ? 0 : 1)
                        .allowsHitTesting(false)
                }
                .animation(.smooth(duration: 0.3), value: shown)
            }
            .scrollIndicators(.hidden)
            .scrollDisabled(sideDrag != nil)
            // The one showing stands out past the column's sides; above and below, the circles scrolling out
            // of it are cut off at its ends.
            .scrollClipDisabled()
            .frame(width: Self.sideWidth, height: height)
            .glass(in: Capsule())
            .mask { Rectangle().padding(.horizontal, -12) }
            .environment(\.colorScheme, .dark)
            // The one showing kept in view as the pages are swiped, and from the start.
            .onChange(of: shown) {
                guard let shown else { return }
                withAnimation(.smooth(duration: 0.3)) { scroller.scrollTo(shown) }
            }
            .onAppear {
                guard let shown else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    scroller.scrollTo(shown)
                }
            }
        }
    }

    /// A favorite down the side: a tap opens it; held, it's picked up, to drag to its new place there.
    private func story(_ favorite: Selection, in city: City) -> some View {
        let held = sideDrag?.held == favorite.id
        return FavoriteStory(favorite: favorite, departures: times(for: favorite))
            .frame(width: Self.storySize, height: Self.storySize)
            .contentShape(Circle())
            .scaleEffect(held ? 1.15 : 1)
            .shadow(color: .black.opacity(held ? 0.5 : 0), radius: 6, y: 2)
            .zIndex(held ? 1 : 0)
            // In the column's own scrolled space, as the finger moving one is: wherever it's scrolled to.
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.columnSpace)) }) { storyFrames[favorite.id] = $0 }
            .onTapGesture {
                Journey.shared.tap("favorite.open", "side")
                go(to: favorite.id, in: city)
            }
            .modifier(ColumnHold { hold in
                switch hold {
                case .began(let at): if sideDrag == nil { pickUp(favorite, in: city, at: at) }
                case .moved(let at): moveHeld(to: at)
                case .ended: dropHeld()
                }
            })
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("\(favorite.lineLabel) at \(favorite.stopName)")
            .accessibilityAction { go(to: favorite.id, in: city) }
    }

    /// The top page's circle, first down the side: a magnifying glass for the stop picker, or the stop
    /// opened from it for now (not a favorite: a dashed ring).
    private func pickerStory(in city: City) -> some View {
        Group {
            if let stop = browsing[city] {
                FavoriteStory(favorite: stop, departures: times(for: stop))
                    .overlay(Circle().strokeBorder(.white.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])))
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: Self.storySize, height: Self.storySize)
                    .background(Circle().fill(.black.opacity(0.55)).padding(4))
                    .overlay(Circle().strokeBorder(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])).padding(1.5))
            }
        }
        .frame(width: Self.storySize, height: Self.storySize)
        .contentShape(Circle())
        .onTapGesture {
            Journey.shared.tap("picker.open", "side")
            go(to: Self.pickerPage, in: city)
        }
        .id(Self.pickerPage)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(browsing[city].map { "\($0.lineLabel) at \($0.stopName), not a favorite" } ?? "Find a stop")
    }

    struct SideDrag {
        let city: City
        var order: [String]
        let held: String
        /// Where the finger is, down the column's content, and how far below the held circle's middle it took
        /// hold: the circle follows it, kept that far above.
        var y: CGFloat
        let grab: CGFloat
    }

    /// The middle of the circle at `slot` down the column (the picker's is 0), all at their own size, as while
    /// one's moved.
    private static func slotCenter(_ slot: Int) -> CGFloat {
        storyGap + CGFloat(slot) * (storySize + storyGap) + storySize / 2
    }

    /// How far the held circle is drawn from its slot: under the finger, wherever that is.
    private func heldOffset(_ id: String, slot: Int, in city: City) -> CGFloat {
        guard let drag = sideDrag, drag.city == city, drag.held == id else { return 0 }
        return drag.y - drag.grab - Self.slotCenter(slot)
    }

    private func pickUp(_ favorite: Selection, in city: City, at: CGPoint) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Journey.shared.tap("favorite.hold", "side")
        withAnimation(.snappy(duration: 0.2)) {
            let order = favorites.filter { $0.city == city }.map(\.id)
            let slot = 1 + trips.filter { $0.city == city }.count + (order.firstIndex(of: favorite.id) ?? 0)
            sideDrag = SideDrag(city: city, order: order, held: favorite.id, y: at.y, grab: at.y - Self.slotCenter(slot))
        }
    }

    /// The held favorite takes the place of the one the finger is over, the others making way.
    private func moveHeld(to at: CGPoint) {
        // Over the bin below them (where it is in the column's space, as the finger is).
        if let moving = sideDrag, let bin = sideBins[moving.city], let origin = columnOrigins[moving.city] {
            let over = bin.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: -6, dy: -6).contains(at)
            if over != overSideBin {
                if over { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
                overSideBin = over
            }
            if over { return }
        }
        guard var moving = sideDrag, let from = moving.order.firstIndex(of: moving.held) else { return }
        // Kept within the column, from the first favorite's slot to the last's.
        let first = 1 + trips.filter { $0.city == moving.city }.count
        let lowest = Self.slotCenter(first) + moving.grab, highest = Self.slotCenter(first + moving.order.count - 1) + moving.grab
        moving.y = min(max(at.y, lowest), highest)
        // Its place: the slot its middle is nearest, from where the slots are, not where the circles are just now
        // (still sliding, they'd have it swap back and forth).
        let middle = moving.y - moving.grab
        let to = min(max(Int(((middle - Self.slotCenter(0)) / (Self.storySize + Self.storyGap)).rounded()) - first, 0), moving.order.count - 1)
        guard to != from else { return sideDrag = moving }
        moving.order.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.snappy(duration: 0.25)) { sideDrag = moving }
    }

    /// Let go of: the city's favorites in their new order (the others' as they were).
    private func dropHeld() {
        guard let moving = sideDrag else { return }
        if overSideBin, let favorite = favorites.first(where: { $0.id == moving.held }) {
            overSideBin = false
            Journey.shared.tap("favorite.delete", "side")
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            let rest = moving.order.filter { $0 != moving.held }
            withAnimation(.smooth(duration: 0.3)) {
                favorites.removeAll { $0.id == moving.held }
                sideDrag = nil
            }
            Selection.remember(favorite)
            // Watching it on the island, no more.
            if BusActivities.shared.isWatching(favorite) { BusActivities.shared.toggle(favorite, departures: [], fetchedAt: .now) }
            // It was showing: the next one, or the picker when it was the last.
            if reels[moving.city] == favorite.id {
                reelProgress[moving.city] = nil
                go(to: rest.first ?? Self.pickerPage, in: moving.city)
            }
            if favorite.id == selection.id, let next = rest.first.flatMap({ id in favorites.first { $0.id == id } }) { select(next) }
            return
        }
        overSideBin = false
        if favorites.filter({ $0.city == moving.city }).map(\.id) != moving.order {
            Journey.shared.tap("favorite.reorder", "side")
            ReorderTip().invalidate(reason: .actionPerformed)
            // The page showing stays, wherever it's moved to: the pages would otherwise stay where they
            // are, on whichever favorite took its place.
            favorites = favorites.filter { $0.city != moving.city } + moving.order.compactMap { id in favorites.first { $0.id == id } }
            // The ring goes by the page showing, not where the pages were scrolled to before they moved; and the
            // pages, laid out again in the new order, to that page.
            reelProgress[moving.city] = nil
            Task {
                try? await Task.sleep(for: .milliseconds(30))
                pageJumps[moving.city, default: 0] += 1
            }
        }
        withAnimation(.snappy(duration: 0.25)) { sideDrag = nil }
    }

    /// Where a route is kept below, and right of: what lies over the top and down the side of the map.
    /// From their sizes, not where they are on screen: that changes as the page slides in, and the map
    /// would be framed again and again on its way.
    private func routeTop(_ city: City) -> CGFloat {
        insets.top + 2 + (overMaps["\(city.rawValue) header"]?.height ?? 30) + 8
    }
    private func routeLeading(_ city: City) -> CGFloat {
        12 + Self.sideWidth + 8
    }

    /// Whether `spot` (in the window) is on what lies over `city`'s maps: the title, the favorites down the side.
    private func isOverMap(_ spot: CGPoint, in city: City) -> Bool {
        return overMaps.contains { $0.key.hasPrefix(city.rawValue) && $0.value.contains(spot) }
    }

    /// Opens `page` (a favorite, or the picker) in `city`, as a swipe to it would.
    private func go(to page: String, in city: City) {
        // Already the one it's to show, but not where the pages are (they were scrolled from under it):
        // let go of it first, else setting it again moves nothing.
        if reels[city] == page, let swiped = reelProgress[city], Int(swiped.rounded()) != Int(pageIndex(of: page, in: city)) {
            reels[city] = nil
            Task { withAnimation(.smooth(duration: 0.4)) { reel(in: city).wrappedValue = page } }
            return
        }
        withAnimation(.smooth(duration: 0.4)) { reel(in: city).wrappedValue = page }
    }

    /// A favorite, over the whole screen: its route and buses, and over the bottom, what and when, with
    /// what to do with it along the right.
    private func reel(_ favorite: Selection, browsed: Bool = false) -> some View {
        let id = browsed ? "\(favorite.city.rawValue) \(Self.pickerPage)" : favorite.id
        // Changing it (the pencil), this same map turns into the stop picker, just where it is: the city's
        // lines blend in over the route, and the map is the fingers' own.
        let changing = editing?.id == id
        return HomeMap(city: favorite.city, open: favorite, feed: feed, expanded: changing, picking: changing, opened: changing,
                       topInset: routeTop(favorite.city), bottomInset: (changing ? 0 : Self.captionRoom) + insets.bottom,
                       leadingInset: routeLeading(favorite.city), gesture: mapGesture?.page == id ? mapGesture?.gesture : nil,
                       editing: changing ? favorite : nil, kindsTop: changing ? Self.kindsTop(insets) : nil) { edited(favorite, to: $0) }
            .overlay {
                if !changing {
                    MapTouches(onGesture: { gesture in mapGesture = gesture.map { (id, $0) } },
                               onHold: browsed ? nil : { hold($0, favorite) },
                               // Not with the favorites zoomed out over it: a hold there is on one of theirs.
                               ignores: { reordering != nil || isOverMap($0, in: favorite.city) })
                }
            }
            .overlay(alignment: .bottom) {
                if !changing { caption(favorite, browsed: browsed).transition(.opacity) }
            }
            .overlay(alignment: .trailing) {
                if changing {
                    railButton("list.bullet", label: "Lines by number") {
                        Journey.shared.tap("picker.toggle", "list")
                        searchingLines = true
                    }
                    .padding(.trailing, 8)
                    .padding(.bottom, 80)
                    .transition(.opacity)
                }
            }
            .modifier(JourneyScreenWhile(shows: changing, name: "picker.map", detail: "edit"))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(favorite.lineLabel) to \(favorite.destination)")
    }

    /// The city's stop picker, after its favorites (or alone, before there are any): a stop picked there
    /// joins them, and opens.
    private func pickerReel(_ city: City, first: Bool) -> some View {
        // The map is the fingers' own here, one finger moving it as on any map: the pages stand still under
        // it (see `onPicker`), the column down the side the way to the others.
        return HomeMap(city: city, expanded: true, picking: true, opened: true, topInset: insets.top + 120, bottomInset: insets.bottom,
                       kindsTop: Self.kindsTop(insets), onPick: picked)
            .id(pickerRounds[city] ?? 0)
            .overlay(alignment: .top) {
                if addingIn == city && !first {
                    Text("Pick a stop to add to your favorites")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .frame(maxWidth: .infinity)
                        .padding(.leading, routeLeading(city))
                        .padding(.trailing, 16)
                        .padding(.top, insets.top + 64)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                if first {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Where do you wait?").font(.headline)
                        Text("Tap a line, then your stop, and watch the \(city.vehicles) not come, live. Add the ones you wait at to your favorites: they line up down the side, and on your widgets.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        // Here the map takes the swipe across: until they've been used, how to get to another city.
                        if !dotsScrubbed, shownCities.count > 1 {
                            Label("To change cities, slide along the dots at the bottom.", systemImage: "hand.point.up.left.and.text")
                                .font(.subheadline.weight(.semibold))
                                .padding(.top, 4)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 12)
                    .padding(.top, insets.top + 120)
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .trailing) {
                VStack(spacing: 14) {
                    railButton("list.bullet", label: "Lines by number") {
                        Journey.shared.tap("picker.toggle", "list")
                        searchingLines = true
                    }
                }
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { pickerRails[city] = $0 }
                .padding(.trailing, 8)
                .padding(.bottom, 80)
            }
    }

    /// A favorite's caption, as a post's: the pill (which puts it up on the island), where it goes and
    /// the next ones after, and a comment on the wait. Along the right, sharing it. Below, the bar
    /// counting down to its next update.
    private func caption(_ favorite: Selection, browsed: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 0) {
                        openFavoriteCard(favorite)
                            .offset(y: favorite.id == selection.id ? pillNudge : 0)
                            .task { if favorite.id == selection.id { await nudgePill() } }
                        if browsed {
                            // Only open for now: a + by its pill keeps it.
                            // The same + as the one below the favorites: both add one.
                            sideCircle {
                                Image(systemName: "plus").font(.system(size: 20, weight: .semibold))
                            } action: { addFavorite(favorite) }
                            .padding(.leading, 8)
                            .accessibilityLabel("Add to favorites")
                            .transition(.scale.combined(with: .opacity))
                        }
                        Spacer(minLength: 0)
                    }
                    details(favorite)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 6) {
                    if browsed {
                        // Only open for now: back to the map for another.
                        railButton("magnifyingglass", label: "Find another stop") { stopBrowsing(in: favorite.city) }
                    } else {
                        railButton("pencil", label: "Change this favorite") { startEditing(favorite) }
                    }
                    railButton("paperplane", label: "Share this stop") {
                        Journey.shared.tap("share.open", Journey.from("map"))
                        sharingFrom = "map"
                        sharing = favorite
                    }
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.bottom, Self.logoRoom + insets.bottom)
            .overlay(alignment: .bottom) {
                RefreshBar(refresh: feed.loaded?.id == favorite.id ? feed.refresh : nil)
                    .opacity(0.8)
            }
        }
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.4), .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .padding(.top, -50)
                .allowsHitTesting(false)
        }
    }

    /// Where it goes and the next ones after the pill's, and a comment on the one that comes next.
    private func details(_ favorite: Selection) -> some View {
        TimelineView(.everyMinute) { context in
            let loaded = times(for: favorite)
            let upcoming = (loaded ?? []).filter { $0.time > context.date.addingTimeInterval(-30) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("To \(favorite.destination)").font(.subheadline.weight(.semibold))
                    if upcoming.count > 1 {
                        Text("then").font(.subheadline)
                        WaitsLabel(departures: Array(upcoming.dropFirst()), date: context.date, count: 2, selection: favorite,
                                   badgeFont: .system(size: 10, weight: .heavy, design: .rounded))
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                            .fixedSize()
                    }
                }
                .lineLimit(1)
                if loaded != nil {
                    // About the line that actually comes next. The punchline matters: it may take a second line.
                    Text(upcoming.first.map { Quip.forWait(until: $0.time, from: context.date, line: $0.line ?? favorite.lineLabel) }
                         ?? Quip.noPrediction(line: favorite.lineLabel))
                        .font(.footnote)
                        .italic()
                        .lineLimit(2)
                        .opacity(0.85)
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
        }
    }

    /// A button along the right of a page, as on a reel: an icon on the map, no button around it.
    private func railButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                .frame(width: 48, height: 48)
                // A soft shade behind it, for a light map.
                .background(Circle().fill(.black.opacity(0.22)).blur(radius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - Moving favorites about

    /// A city's favorites zoomed out, in order, the one held following the finger.
    struct Reordering {
        let city: City
        var order: [String]
        var held: String?
        /// Where the finger is, in the window.
        var at: CGPoint = .zero
        /// Held on its page: where the finger came down, and the favorite's place among them then. The
        /// zoomed-out favorites are moved so its own place is under the finger, until it's let go.
        var anchor: (point: CGPoint, index: Int)?
    }

    /// A map held, and moved, and let go of: zoomed out to the city's favorites, to move it among them.
    private func hold(_ event: MapTouches.Hold, _ favorite: Selection) {
        switch event {
        case .began(let at):
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            Journey.shared.tap("favorite.hold")
            withAnimation(.smooth(duration: 0.35)) {
                let order = favorites.filter { $0.city == favorite.city }.map(\.id)
                reordering = Reordering(city: favorite.city, order: order, held: favorite.id, at: at,
                                        anchor: (at, order.firstIndex(of: favorite.id) ?? 0))
            }
        case .moved(let at): drag(to: at)
        case .ended: drop()
        }
    }

    /// The held favorite under the finger: it takes the place of the one it's over, the others making way.
    private func drag(to at: CGPoint) {
        guard var moving = reordering, let held = moving.held else { return }
        moving.at = at
        // Moving off where it was held: the others glide back to the middle, every one in reach.
        if let anchor = moving.anchor, hypot(at.x - anchor.point.x, at.y - anchor.point.y) > 30 {
            moving.anchor = nil
            withAnimation(.smooth(duration: 0.4)) { reordering = moving }
            return
        }
        // Its place: the one nearest the finger, wherever that is, but not while it's over the bin.
        let layout = gridLayout(count: moving.order.count, screen: gridScreen)
        if gridScreen != .zero, !binFrame.contains(at), let from = moving.order.firstIndex(of: held),
           case let to = layout.place(at: at), to != from {
            withAnimation(.snappy(duration: 0.25)) {
                moving.order.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
                reordering = moving
            }
            UISelectionFeedbackGenerator().selectionChanged()
        } else {
            reordering = moving
        }
    }

    /// Let go of: on the bin, deleted; anywhere else, in its new place.
    private func drop() {
        guard var moving = reordering, let held = moving.held else { return }
        moving.held = nil
        // Back in the middle, now nothing's held.
        moving.anchor = nil
        if binFrame.contains(moving.at), let favorite = favorites.first(where: { $0.id == held }) {
            Journey.shared.tap("favorite.delete")
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            moving.order.removeAll { $0 == held }
            withAnimation(.smooth(duration: 0.3)) {
                favorites.removeAll { $0.id == held }
                reordering = moving
            }
            Selection.remember(favorite)
            if held == selection.id, let next = moving.order.first.flatMap({ id in favorites.first { $0.id == id } }) { select(next) }
            if moving.order.isEmpty { closeGrid(on: Self.pickerPage) }
            return
        }
        let before = favorites.filter { $0.city == moving.city }.map(\.id)
        if before != moving.order {
            Journey.shared.tap("favorite.reorder")
            ReorderTip().invalidate(reason: .actionPerformed)
            // Only this city's order changes; each city keeps its own list.
            favorites = favorites.filter { $0.city != moving.city } + moving.order.compactMap { id in favorites.first { $0.id == id } }
        }
        withAnimation(.snappy(duration: 0.25)) { reordering = moving }
    }

    /// Back to the reels, on `page` (the open favorite, unless given).
    private func closeGrid(on page: String? = nil) {
        guard let city = reordering?.city else { return }
        reels[city] = page ?? (selection.city == city && isFavorite(selection) ? selection.id : reels[city])
        withAnimation(.smooth(duration: 0.35)) { reordering = nil }
    }

    /// The zoomed-out favorites, as many to a row as fit them all on the screen, and the bin below them
    /// while one is held.
    /// Where the zoomed-out favorites are laid out: how many across, each one's size, and where the grid
    /// starts, `count` of them on a `screen`.
    struct GridLayout {
        let columns: Int
        let width: CGFloat
        let cellHeight: CGFloat
        let gap: CGFloat
        let top: CGFloat
        let count: Int

        /// The middle of the place at `index`.
        func middle(_ index: Int) -> CGPoint {
            CGPoint(x: gap + CGFloat(index % columns) * (width + gap) + width / 2,
                    y: top + CGFloat(index / columns) * (cellHeight + gap) + cellHeight / 2)
        }

        /// The place nearest `point`: from the grid's layout, not where the cards are just now (still sliding,
        /// they'd have the held one swap back and forth). Above the first row, the first; past the last one
        /// (the rest of its row, below it), the last.
        func place(at point: CGPoint) -> Int {
            let column = min(max(Int((point.x - gap / 2) / (width + gap)), 0), columns - 1)
            let row = max(Int(floor((point.y - top + gap / 2) / (cellHeight + gap))), 0)
            return min(row * columns + column, count - 1)
        }
    }

    private func gridLayout(count: Int, screen: CGSize) -> GridLayout {
        let gap: CGFloat = 12
        let top = insets.top + 56, bottom = insets.bottom + 110
        // Two to a row if they fit, else more.
        let columns = (2...4).first { columns in
            let width = (screen.width - gap * CGFloat(columns + 1)) / CGFloat(columns)
            let rows = (count + columns - 1) / columns
            return CGFloat(rows) * (width * screen.height / screen.width + gap) <= screen.height - top - bottom
        } ?? 4
        let width = (screen.width - gap * CGFloat(columns + 1)) / CGFloat(columns)
        let cellHeight = width * screen.height / screen.width
        let rows = (count + columns - 1) / columns
        // In the middle of the room for them.
        let tall = CGFloat(rows) * (cellHeight + gap) - gap
        return GridLayout(columns: columns, width: width, cellHeight: cellHeight, gap: gap,
                          top: max(top, top + (screen.height - top - bottom - tall) / 2), count: count)
    }

    private func grid(_ moving: Reordering) -> some View {
        GeometryReader { geometry in
            let screen = geometry.size
            let shown = moving.order.compactMap { id in favorites.first { $0.id == id } }
            let layout = gridLayout(count: shown.count, screen: screen)
            let gap = layout.gap, columns = layout.columns, width = layout.width
            let scale = width / screen.width
            let gridTop = layout.top
            // Held on its page: its own place under the finger, the others around it in their order.
            let shift: CGSize = moving.anchor.map { anchor in
                let middle = layout.middle(anchor.index)
                return CGSize(width: anchor.point.x - middle.x, height: anchor.point.y - middle.y)
            } ?? .zero
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.94)
                    .onTapGesture { closeGrid() }
                HStack {
                    Text(moving.held == nil ? "Hold one to move it" : "Drop it where it goes")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") { Journey.shared.tap("favorite.grid.done"); closeGrid() }
                        .font(.headline)
                        .tint(.white)
                }
                .padding(.horizontal, 16)
                .padding(.top, insets.top + 12)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: gap), count: columns), spacing: gap) {
                    ForEach(shown) { favorite in
                        gridCell(favorite, held: moving.held == favorite.id, screen: screen, scale: scale)
                    }
                }
                .padding(.horizontal, gap)
                .padding(.top, gridTop)
                .offset(shift)
                // The one held, under the finger, and the bin to drop it on.
                if let held = moving.held, let favorite = favorites.first(where: { $0.id == held }) {
                    heldCard(favorite, at: moving.at, screen: screen, scale: scale)
                    bin(over: binFrame.contains(moving.at), screen: screen)
                }
            }
        }
        .ignoresSafeArea()
        .onGeometryChange(for: CGSize.self, of: \.size) { gridScreen = $0 }
        .environment(\.colorScheme, .dark)
    }

    /// A favorite zoomed out, to tap open or hold to move.
    private func gridCell(_ favorite: Selection, held: Bool, screen: CGSize, scale: CGFloat) -> some View {
        card(favorite, screen: screen, scale: scale)
            .opacity(held ? 0 : 1)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { cellFrames[favorite.id] = $0 }
            .onTapGesture {
                Journey.shared.tap("stop.open", Journey.from("grid"))
                select(favorite)
                closeGrid(on: favorite.id)
            }
            .gesture(LongPressGesture(minimumDuration: 0.25)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
                .onChanged { value in
                    guard case .second(true, let drag?) = value else { return }
                    if reordering?.held == nil {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        withAnimation(.snappy(duration: 0.2)) {
                            reordering?.held = favorite.id
                            reordering?.at = drag.location
                        }
                    }
                    self.drag(to: drag.location)
                }
                .onEnded { _ in drop() })
    }

    /// The favorite being moved, a little bigger than the rest, shrinking over the bin.
    private func heldCard(_ favorite: Selection, at: CGPoint, screen: CGSize, scale: CGFloat) -> some View {
        let over = binFrame.contains(at)
        return card(favorite, screen: screen, scale: scale)
            .scaleEffect(over ? 0.7 : 1.08)
            .opacity(over ? 0.6 : 1)
            .shadow(color: .black.opacity(0.6), radius: 16, y: 6)
            .position(at)
            .allowsHitTesting(false)
            .animation(.snappy(duration: 0.2), value: over)
    }

    /// Where a favorite let go of is deleted.
    private func bin(over: Bool, screen: CGSize) -> some View {
        Image(systemName: "trash")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: over ? 72 : 60, height: over ? 72 : 60)
            .background(over ? Color.red : Color.white.opacity(0.18), in: Circle())
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global).insetBy(dx: -16, dy: -16) }) { binFrame = $0 }
            .onDisappear { binFrame = .null }
            .position(x: screen.width / 2, y: screen.height - insets.bottom - 56)
            .accessibilityLabel("Delete")
            .animation(.snappy(duration: 0.2), value: over)
            .transition(.scale.combined(with: .opacity))
    }

    /// A favorite's page, zoomed out: its map as it shows on the screen, `scale` as big, and its pill.
    private func card(_ favorite: Selection, screen: CGSize, scale: CGFloat) -> some View {
        // A picture of its map, drawn ahead of time with the widgets' (see WidgetMapPainter): a live map each
        // would load at once as the grid zooms out, and make it stutter.
        PagePicture(favorite: favorite, dark: colorScheme == .dark) {
            HomeMap(city: favorite.city, open: favorite, topInset: insets.top + 120, bottomInset: insets.bottom + 60)
                .frame(width: screen.width, height: screen.height)
                .scaleEffect(scale, anchor: .topLeading)
                .environment(\.colorScheme, colorScheme)
        }
            .frame(width: screen.width * scale, height: screen.height * scale, alignment: .topLeading)
            .clipped()
            .allowsHitTesting(false)
            // Along the top: Apple's mark and its legal link are on the picture's bottom, and stay in sight.
            .overlay(alignment: .topLeading) {
                HStack(spacing: 5) {
                    LineBadges(parts: favorite.badgeParts, font: .system(.caption2, design: .rounded).weight(.heavy), round: favorite.roundBadge)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(favorite.stopName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(favorite.id == selection.id ? 0.7 : 0.15), lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(favorite.lineLabel) at \(favorite.stopName)")
    }

    // MARK: - The open stop

    /// The favorite's pill: line, stop and the next departure, as the Dynamic Island would show it. Tapping
    /// it puts it up there (or on the Lock Screen, without an island), or takes it off again.
    private func openFavoriteCard(_ open: Selection) -> some View {
        let (departures, dimmed) = shownDepartures(for: open)
        let canWatch = BusActivities.shared.isAvailable
        let watching = BusActivities.shared.isWatching(open)
        return Button {
            Journey.shared.tap("pill", watching ? "unwatch" : "watch")
            BusActivities.shared.toggle(open, departures: departures,
                                        fetchedAt: open.id == selection.id ? feed.refresh?.fetchedAt ?? .now : .now)
        } label: {
            TimelineView(.everyMinute) { context in
                let next = departures.first { $0.time > context.date.addingTimeInterval(-30) }
                let showsTime = open.id != selection.id || feed.error == nil
                // Up on the island, it leaves its outline here, still saying what's up there.
                IslandPill(badges: open.badgeParts, round: open.roundBadge, next: showsTime ? next : nil, middle: open.stopName, dimmed: dimmed, lifted: watching)
                    .frame(height: 36)
                    // A little of the map through it, as through what else lies over the map.
                    .opacity(0.88)
            }
        }
        .buttonStyle(.plain)
        // Without Live Activities (turned off in Settings) there's nowhere for it to go.
        .disabled(!canWatch)
        .modifier(StalkTipAnchor(shows: open.id == selection.id))
        .accessibilityLabel("\(open.lineLabel) at \(open.stopName)")
        .accessibilityHint(!canWatch ? ""
                           : watching ? "Stops watching it from \(Island.frame != nil ? "the Dynamic Island" : "the Lock Screen")"
                           : "Watches it from \(Island.frame != nil ? "the Dynamic Island" : "the Lock Screen")")
    }

    /// Hops the pill up toward the island and back, once ever, a moment after it first shows: a hint
    /// that it goes up there. The tip by it says so in words.
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

    /// The departures shown for `open`: the open stop's live feed (dimmed while it still holds the
    /// previous stop's), or for any other, what the favorites feed has.
    private func shownDepartures(for open: Selection) -> (departures: [Departure], dimmed: Bool) {
        if open.id == selection.id { return (departures, isStale) }
        return (favoritesFeed.departures[open.id] ?? [], false)
    }

    /// The departures known for `favorite`, or none yet.
    private func times(for favorite: Selection) -> [Departure]? {
        if favorite.id == selection.id, loaded?.id == favorite.id { return departures }
        return favoritesFeed.departures[favorite.id]
    }

    // MARK: - Opening stops

    /// A stop picked, on the map or from the lines by number: it opens on the top page, for now, to be
    /// added to the favorites or not. One that's a favorite already just opens.
    private func picked(_ picked: Selection) {
        Journey.shared.tap("stop.open", Journey.from("picker"))
        searchingLines = false
        if isFavorite(picked) { addingIn = nil; return show(picked) }
        if addingIn == picked.city {
            addingIn = nil
            return addFavorite(picked, from: "side")
        }
        withAnimation(.smooth(duration: 0.35)) { browsing[picked.city] = picked }
        select(picked)
        withAnimation(.smooth(duration: 0.4)) { page = picked.city.rawValue }
        go(to: Self.pickerPage, in: picked.city)
    }

    /// The stop open on the top page, kept: it joins the favorites (at the end) and opens there, the top
    /// page going back to the map for the next.
    private func addFavorite(_ stop: Selection, from place: String = "pill") {
        Journey.shared.tap("favorite.added", Journey.from(place))
        if !isFavorite(stop) { favorites.append(stop) }
        show(stop)
        Task {
            try? await Task.sleep(for: .seconds(0.6))
            browsing[stop.city] = nil
            pickerRounds[stop.city, default: 0] += 1
        }
    }

    /// The + below the favorites: the picker on top, to add a favorite from; again (the ✕), back to the
    /// favorite that was open.
    private func toggleAdding(in city: City) {
        if addingIn == city {
            Journey.shared.tap("picker.close", "side")
            addingIn = nil
            let back = isFavorite(selection) && selection.city == city ? selection.id : favorites.last { $0.city == city }?.id
            if let back { go(to: back, in: city) }
        } else {
            Journey.shared.tap("favorite.add", Journey.from("side"))
            addingIn = city
            withAnimation(.smooth(duration: 0.35)) { browsing[city] = nil }
            go(to: Self.pickerPage, in: city)
        }
    }

    /// Back to the map on the top page, for another stop.
    private func stopBrowsing(in city: City) {
        Journey.shared.tap("picker.again")
        pickerRounds[city, default: 0] += 1
        withAnimation(.smooth(duration: 0.35)) { browsing[city] = nil }
    }

    /// Opens `stop`: its city's page, and its own in it, if it's a favorite.
    private func show(_ stop: Selection) {
        select(stop)
        withAnimation(.smooth(duration: 0.4)) {
            page = stop.city.rawValue
            if isFavorite(stop) { reels[stop.city] = stop.id }
        }
    }

    /// Back from the map of cities to the open one's page.
    private func backFromCities() {
        withAnimation(.smooth(duration: 0.4)) { page = selection.city.rawValue }
    }

    /// Whether `stop`'s times are followed live: a favorite, or the stop open for now in its city.
    private func followsLive(_ stop: Selection) -> Bool {
        isFavorite(stop) || browsing[stop.city]?.id == stop.id
    }

    private func isFavorite(_ stop: Selection) -> Bool {
        favorites.contains { $0.id == stop.id }
    }

    /// On a fresh install, start with the default stop of whichever supported city the proxy
    /// thinks we're in (a rough IP-based guess: no location permission, nothing stored).
    private func startInNearestCity() async {
        guard !Selection.hasSavedChoice else { return }
        let start = (await TransitService.nearestCity() ?? .sf).defaultSelection
        Selection.current = start
        if start.id != selection.id { selection = start }
    }

    /// Opens the line a widget row showed, over whatever was on screen.
    /// `on`: where it was tapped, "home", "lock", "activity" or "island" (see `URL.tapped(on:)`).
    private func openFromWidget(_ tapped: Selection, on place: String?) {
        Journey.shared.tap("widget.open", place)
        Journey.shared.tap("stop.open", Journey.from(place.map { "widget \($0)" } ?? "widget"))
        searchingLines = false
        sharing = nil
        reordering = nil
        show(tapped)
    }

    private func takeWidgetTap() {
        if let link = WidgetTap.take(), let tapped = Selection(openURL: link) { openFromWidget(tapped, on: link.tappedOn) }
    }

    /// Makes `picked` the line and stop open in the app.
    private func select(_ picked: Selection) {
        guard picked.id != selection.id else { return }
        Selection.current = picked
        Journey.shared.setCity(picked.city.rawValue)
        selection = picked
    }

    /// The stop switching to `city` opens: the one you last had open there if it's a favorite,
    /// else your first favorite there, else the city's default stop.
    private func opening(_ city: City) -> Selection {
        let cityFavorites = favorites.filter { $0.city == city }
        let last = Selection.lastOpened(in: city)
        return cityFavorites.first { $0.id == last?.id } ?? cityFavorites.first ?? city.defaultSelection
    }

    /// The cities with a page: the chosen ones, and the open one should it not be (a widget's tap,
    /// before the welcome map's Done).
    private var shownCities: [City] { City.allCases.filter { cities.contains($0) || $0 == selection.city } }

    /// Saves which cities to show; when the open one is left out, the first one left opens.
    private func setCities(_ chosen: [City]) {
        City.chosen = chosen
        cities = City.chosen
        if !cities.contains(selection.city), let first = cities.first { switchCity(to: first, from: "cities") }
    }

    /// `from`: how, for Journey: "swipe", "dots", or "cities" (the open one left out on the map of them).
    private func switchCity(to city: City, from: String) {
        guard city != selection.city else { return }
        Journey.shared.tap("city.switch", "\(city.rawValue), \(Journey.from(from))")
        Selection.setLastOpened(selection)
        let shown = reels[city].flatMap { id in favorites.first { $0.id == id } }
        select(shown ?? opening(city))
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

/// A page's map's touches, watched without taking them: one finger's go on to the pages (and taps to
/// the map, for the picker). Two fingers move the map instead, through `onGesture`, the pages holding
/// still meanwhile; and a finger held still, `onHold`, then as it moves and lets go.
///
/// The gestures watch the whole window, not the map: UIKit hands a touch to the view it lands on, and
/// SwiftUI doesn't land a second finger where the first one went.
struct MapTouches: UIViewRepresentable {
    let onGesture: (MapGesture?) -> Void
    var onHold: ((Hold) -> Void)? = nil
    /// A tap that's only a tap, where it landed in the window. SwiftUI's buttons over the map aren't
    /// views of their own, so a tap on one comes here too.
    /// Where in the window a finger held or tapped isn't the map's (what lies over it has its own).
    var ignores: (CGPoint) -> Bool = { _ in false }
    var onTap: ((CGPoint) -> Void)? = nil

    /// A finger held on the map, where it is in the window.
    enum Hold {
        case began(CGPoint), moved(CGPoint), ended
    }

    func makeUIView(context: Context) -> Watcher { Watcher() }

    func updateUIView(_ view: Watcher, context: Context) {
        view.onGesture = onGesture
        view.onHold = onHold
        view.onTap = onTap
        view.ignores = ignores
    }

    final class Watcher: UIView, UIGestureRecognizerDelegate {
        var onGesture: ((MapGesture?) -> Void)?
        var onHold: ((Hold) -> Void)?
        var onTap: ((CGPoint) -> Void)?
        var ignores: (CGPoint) -> Bool = { _ in false }
        private let tap = UITapGestureRecognizer()
        private let pinch = UIPinchGestureRecognizer()
        private let pan = UIPanGestureRecognizer()
        private let hold = UILongPressGestureRecognizer()
        /// The pages around the map, and where they were as the fingers came down: held there while
        /// two fingers move the map or one holds it, as the first may have started scrolling them.
        private var stilled: [(view: UIScrollView, offset: CGPoint)] = []
        private var start: CGPoint?

        override init(frame: CGRect) {
            super.init(frame: frame)
            for recognizer in [pinch, pan, hold, tap] as [UIGestureRecognizer] {
                recognizer.delegate = self
                recognizer.cancelsTouchesInView = false
                recognizer.delaysTouchesEnded = false
            }
            pinch.addTarget(self, action: #selector(moved))
            pan.addTarget(self, action: #selector(moved))
            pan.minimumNumberOfTouches = 2
            hold.addTarget(self, action: #selector(held(_:)))
            tap.addTarget(self, action: #selector(tapped))
            hold.minimumPressDuration = 0.4
            // Held, a tap on what's under the finger (the pill, say) isn't one.
            hold.cancelsTouchesInView = true
        }

        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            for recognizer in [pinch, pan, hold, tap] as [UIGestureRecognizer] {
                recognizer.view?.removeGestureRecognizer(recognizer)
                window?.addGestureRecognizer(recognizer)
            }
        }

        /// Takes no touches itself: they go to the map and the pages.
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

        /// Only touches on this map, on the page that's showing.
        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard window != nil, bounds.contains(touch.location(in: self)) else { return false }
            if gesture === hold, onHold == nil { return false }
            if gesture === hold || gesture === tap, ignores(touch.location(in: nil)) { return false }
            if gesture === tap, onTap == nil { return false }
            // The first finger down: where everything is, before it scrolls anything.
            if gesture === pinch, pinch.numberOfTouches == 0 {
                stilled = []
                var view = superview
                while let current = view {
                    if let scrollView = current as? UIScrollView { stilled.append((scrollView, scrollView.contentOffset)) }
                    view = current.superview
                }
            }
            return true
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        /// Turning a scroll view's pan off and on again stops whatever it had started.
        private func still() {
            for (view, offset) in stilled {
                view.panGestureRecognizer.isEnabled = false
                view.setContentOffset(offset, animated: false)
            }
        }

        private func release() {
            stilled.forEach { $0.view.panGestureRecognizer.isEnabled = true }
            stilled = []
        }

        @objc private func moved(_ gesture: UIGestureRecognizer) {
            switch gesture.state {
            case .began:
                still()
                if start == nil { start = gesture.location(in: self) }
                report()
            case .changed:
                report()
            default:
                // Both end; the gesture is over once neither is going.
                guard ![pinch, pan].contains(where: { $0.state == .began || $0.state == .changed }) else { return }
                if hold.state != .began, hold.state != .changed { release() }
                start = nil
                onGesture?(nil)
            }
        }

        @objc private func tapped() { onTap?(tap.location(in: nil)) }

        @objc private func held(_ hold: UILongPressGestureRecognizer) {
            let at = hold.location(in: nil)
            switch hold.state {
            case .began:
                still()
                onHold?(.began(at))
            case .changed:
                onHold?(.moved(at))
            default:
                release()
                onHold?(.ended)
            }
        }

        private func report() {
            guard let start else { return }
            let going = pan.state == .began || pan.state == .changed
            onGesture?(MapGesture(scale: pinch.state == .began || pinch.state == .changed ? pinch.scale : 1,
                                  translation: going ? pan.translation(in: self) : .zero, start: start))
        }

        deinit {
            for recognizer in [pinch, pan, hold, tap] as [UIGestureRecognizer] { recognizer.view?.removeGestureRecognizer(recognizer) }
        }
    }
}

/// Held, a favorite down the side is picked up to move. From iOS 18 by UIKit's own long press, as SwiftUI's
/// there stops the column from scrolling at all; a finger that moves first scrolls it instead, and once one's
/// held the column stands still (`scrollDisabled`).
private struct ColumnHold: ViewModifier {
    let onHold: (MapTouches.Hold) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.gesture(Recognizer(onHold: onHold))
        } else {
            content.gesture(LongPressGesture(minimumDuration: 0.4)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(ContentView.columnSpace)))
                .onChanged { value in
                    guard case .second(true, let drag) = value else { return }
                    onHold(.began(drag?.location ?? .zero))
                    if let drag { onHold(.moved(drag.location)) }
                }
                .onEnded { _ in onHold(.ended) })
        }
    }

    @available(iOS 18.0, *)
    struct Recognizer: UIGestureRecognizerRepresentable {
        let onHold: (MapTouches.Hold) -> Void

        func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
            let hold = UILongPressGestureRecognizer()
            hold.minimumPressDuration = 0.4
            hold.delegate = context.coordinator
            return hold
        }

        func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

        func handleUIGestureRecognizerAction(_ hold: UILongPressGestureRecognizer, context: Context) {
            let at = context.converter.location(in: .named(ContentView.columnSpace))
            switch hold.state {
            case .began: onHold(.began(at))
            case .changed: onHold(.moved(at))
            case .ended, .cancelled, .failed: onHold(.ended)
            default: break
            }
        }

        final class Coordinator: NSObject, UIGestureRecognizerDelegate {
            func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
        }
    }
}

/// A favorite's page as a picture (WidgetMapShape.page), read once and kept; until there is one, `fallback`.
private struct PagePicture<Fallback: View>: View {
    let favorite: Selection
    let dark: Bool
    @ViewBuilder let fallback: () -> Fallback

    var body: some View {
        if let image = Self.image(favorite, dark: dark) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            fallback()
        }
    }

    private static func image(_ favorite: Selection, dark: Bool) -> UIImage? {
        let key = favorite.id + (dark ? "-dark" : "")
        if let kept = pagePictures[key] { return kept }
        guard let url = WidgetMaps.imageURL(favorite, .page, dark: dark),
              let image = UIImage(contentsOfFile: url.path(percentEncoded: false)) else { return nil }
        pagePictures[key] = image
        return image
    }
}

/// The pictures PagePicture has read, by favorite and appearance.
@MainActor private var pagePictures: [String: UIImage] = [:]

/// The tip about putting favorites in order, pointing at the column of them.
private struct ReorderTipAnchor: ViewModifier {
    let shows: Bool

    func body(content: Content) -> some View {
        // One tip at a time: the pill's first, while it's up.
        if shows, !StalkTip(island: Island.frame != nil).shouldDisplay {
            content.popoverTip(ReorderTip(), arrowEdge: .leading)
        } else {
            content
        }
    }
}

/// The tip about putting the pill up on the island, by the open favorite's pill only.
private struct StalkTipAnchor: ViewModifier {
    let shows: Bool

    func body(content: Content) -> some View {
        if shows {
            content.popoverTip(StalkTip(island: Island.frame != nil), arrowEdge: .bottom)
        } else {
            content
        }
    }
}

/// A favorite on the top bar, as a story: its lines, condensed, and when the next one comes, in a ring of
/// its lines' colors.
private struct FavoriteStory: View {
    let favorite: Selection
    let departures: [Departure]?

    var body: some View {
        let colors = favorite.badgeParts.map { Color(hex: $0.color) ?? LineBadge.red }
        TimelineView(.everyMinute) { context in
            let next = departures?.first { $0.time > context.date.addingTimeInterval(-30) }
            VStack(spacing: 1) {
                LineBadges(parts: favorite.badgeParts, font: .system(size: 10, weight: .heavy, design: .rounded), round: favorite.roundBadge)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                    .frame(maxWidth: 36)
                Text(next.map { Self.minutes(until: $0.time, from: context.date) } ?? (departures == nil ? "…" : "–"))
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(next?.isLive == true ? .green : .gray)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black.opacity(0.7), in: Circle())
            .padding(3)
            .overlay {
                Circle().strokeBorder(AngularGradient(colors: colors + [colors[0]], center: .center), lineWidth: 1.5)
                    .opacity(0.55)
            }
        }
    }

    /// "now", "4m", "1h"…, as short as a circle needs.
    static func minutes(until time: Date, from now: Date) -> String {
        let minutes = Int(time.timeIntervalSince(now) / 60)
        if minutes < 1 { return "now" }
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h"
    }
}

/// Reports how far a paging scroll view is scrolled, in pages. Needs iOS 18; before that, nothing.
private struct PageProgress: ViewModifier {
    var axis: Axis = .vertical
    let onChange: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                axis == .vertical
                    ? geometry.containerSize.height > 0 ? geometry.contentOffset.y / geometry.containerSize.height : 0
                    : geometry.containerSize.width > 0 ? geometry.contentOffset.x / geometry.containerSize.width : 0
            } action: { _, new in
                onChange(new)
            }
        } else {
            content
        }
    }
}

private extension View {
    /// The dark glass of what lies over the maps: a little of the map shows through.
    func glass(in shape: some Shape) -> some View {
        background(shape.fill(.black.opacity(0.3)))
            .background(shape.fill(.ultraThinMaterial).opacity(0.75))
    }
}

/// Tells Journey a screen is in front while `shows`, and gone again after.
private struct JourneyScreenWhile: ViewModifier {
    let shows: Bool
    let name: String
    let detail: String

    func body(content: Content) -> some View {
        content.onChange(of: shows) { _, now in
            if now { Journey.shared.show(name, detail: detail) } else { Journey.shared.hide(name) }
        }
    }
}

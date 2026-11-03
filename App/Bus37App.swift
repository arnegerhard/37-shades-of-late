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
            if let screen = ScreenshotScreen.current, [.widgets, .lock, .lockwidget].contains(screen) {
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
    /// The last tap on a city's picker, and where the buttons along its side are, whose taps aren't the map's.
    @State private var pickerTaps: [City: MapTap] = [:]
    @State private var pickerRails: [City: CGRect] = [:]
    /// Where what lies over each city's pages is (the title, the favorites down the side), whose taps
    /// aren't the picker's either.
    @State private var overMaps: [String: CGRect] = [:]
    /// The city a + has added a picker to, after its favorites. A city without favorites always has one.
    @State private var addingIn: City?
    /// How far each city's pages are swiped, in pages (1.5: halfway from its second favorite to its third),
    /// for the ring down the side to follow.
    @State private var reelProgress: [City: CGFloat] = [:]
    /// A favorite held down the side, being moved among the others there, and where each circle is.
    @State private var sideDrag: SideDrag?
    @State private var storyFrames: [String: CGRect] = [:]
    /// How far the cities' pages are swiped, in pages, for the ring along the cities to follow.
    @State private var cityProgress: CGFloat?
    /// Where the city switch under way came from, for Journey, when not a swipe (a dot).
    @State private var switchingFrom: String?
    /// Whether the cities' dots show: for a few seconds after the app opens or the cities are swiped,
    /// then they fade. Each swipe starts the wait again.
    @State private var dotsAwake = true
    @State private var dotsWoken = 0
    /// The screen's height, for the favorites' share of it.
    @State private var screenHeight: CGFloat = 0
    /// A city's favorites zoomed out to move about, after holding one.
    @State private var reordering: Reordering?
    /// Where each zoomed-out favorite is, and the bin, in the window.
    @State private var cellFrames: [String: CGRect] = [:]
    @State private var binFrame: CGRect = .null
    /// The screen's safe area: the pages go under it, what's over them stays clear of it.
    @State private var insets = EdgeInsets()
    /// The pill hopping toward the island, the first time it's there: it goes up there.
    @State private var pillNudge: CGFloat = 0
    @AppStorage("pillNudged") private var pillNudged = false
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
        // Only a favorite's times are followed live.
        .task(id: isFavorite(selection) ? selection : nil) {
            if isFavorite(selection) { await feed.follow(selection) }
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
                Task { try? await Task.sleep(for: .seconds(1.5)); sharingFrom = "map"; sharing = selection }
            case .lines: addingIn = selection.city; reels[selection.city] = Self.pickerPage
            case .cities: page = Self.citiesPage
            case .stops:
                addingIn = selection.city
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
                LinePicker(onPick: picked)
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
            HStack(spacing: 7) {
                ForEach(Array(cities.enumerated()), id: \.element) { index, city in
                    let close = max(0, 1 - abs(CGFloat(index) - at))
                    Circle()
                        .fill(.white.opacity(0.45 + 0.55 * close))
                        .frame(width: 6 + 4 * close, height: 6 + 4 * close)
                        .frame(width: 12, height: 22)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            switchingFrom = "dots"
                            withAnimation(.smooth(duration: 0.4)) { page = city.rawValue }
                        }
                        .accessibilityElement()
                        .accessibilityLabel(city.name)
                        .accessibilityAddTraits(index == near ? [.isButton, .isSelected] : .isButton)
                }
                let close = max(0, 1 - abs(CGFloat(cities.count) - at))
                Image(systemName: "plus")
                    .font(.system(size: 8 + 3 * close, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.45 + 0.55 * close))
                    .frame(width: 12, height: 22)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Journey.shared.tap("cities.edit", "dots")
                        switchingFrom = "dots"
                        withAnimation(.smooth(duration: 0.4)) { page = Self.citiesPage }
                    }
                    .accessibilityLabel("Choose cities")
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
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .glass(in: Capsule())
        // The name fading into the next, and the bubble growing or shrinking to it.
        .animation(.smooth(duration: 0.3), value: name)
        .environment(\.colorScheme, .dark)
        // On the line of Apple's logo, under the caption, clear of the home indicator.
        .padding(.bottom, max(insets.bottom - 22, 6))
        .opacity(reordering == nil && dotsAwake ? 1 : 0)
        .allowsHitTesting(dotsAwake)
        .task(id: dotsWoken) {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.6)) { dotsAwake = false }
        }
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
        .scrollDisabled(reordering != nil)
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

    /// One city: its favorites one under another, a screen each, and the picker after them. The maps
    /// next to the one showing are made ahead, so they've framed their route by the time they slide in;
    /// those further away are left out until then.
    private func cityPage(_ city: City) -> some View {
        let cityFavorites = favorites.filter { $0.city == city }
        let shown = reel(in: city).wrappedValue
        let at = cityFavorites.firstIndex { $0.id == shown } ?? cityFavorites.count
        // Where the pages actually are, which a page view just made may not have scrolled to yet.
        let showing = reelProgress[city].map { Int($0.rounded()) }
        return ScrollViewReader { scroller in
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(Array(cityFavorites.enumerated()), id: \.element.id) { index, favorite in
                    Group {
                        if abs(index - at) <= 1 || showing.map({ abs(index - $0) <= 1 }) == true { reel(favorite) } else { Color.black }
                    }
                    .containerRelativeFrame([.horizontal, .vertical])
                    .id(favorite.id)
                }
                if hasPicker(city) {
                    pickerReel(city, first: cityFavorites.isEmpty)
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(Self.pickerPage)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: reel(in: city))
        .scrollIndicators(.hidden)
        .scrollDisabled(reordering != nil)
        .modifier(PageProgress { reelProgress[city] = $0 })
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
    }

    /// Which page `city` shows: the one it was left on, else the open stop or the favorite switching there
    /// opens, else its picker. Swiping to a favorite makes it the open stop.
    private func reel(in city: City) -> Binding<String?> {
        Binding {
            if let shown = reels[city], shown == Self.pickerPage && hasPicker(city) || favorites.contains(where: { $0.id == shown }) { return shown }
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
                // Left without picking: the picker goes again, until the next +.
                if addingIn == city { addingIn = nil }
            }
            guard city == selection.city, new != selection.id, let favorite = favorites.first(where: { $0.id == new }) else { return }
            Journey.shared.tap("stop.open", Journey.from("swipe"))
            select(favorite)
        }
    }

    /// Whether `city` has a picker after its favorites: added with the +, or with none to show yet.
    private func hasPicker(_ city: City) -> Bool {
        addingIn == city || !favorites.contains { $0.city == city }
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

    /// Down the left, as stories are: the city's favorites to jump to, in up to a share of the screen
    /// (a slice of the next saying there are more, the rest a scroll away), and below them a + to add
    /// one, which puts a picker after them (an ✕ while it's there, to leave it).
    @ViewBuilder private func side(_ city: City) -> some View {
        let cityFavorites = favorites.filter { $0.city == city }
        if !cityFavorites.isEmpty {
            VStack(spacing: 10) {
                // While one's moved, in the order it's being moved into.
                let shown = sideDrag?.city == city
                    ? sideDrag!.order.compactMap { id in cityFavorites.first { $0.id == id } } : cityFavorites
                favoritesColumn(shown, shown: reel(in: city).wrappedValue, in: city)
                sideCircle {
                    Image(systemName: addingIn == city ? "xmark" : "plus").font(.system(size: 20, weight: .semibold))
                } action: {
                    toggleAdding(in: city)
                }
                .accessibilityLabel(addingIn == city ? "Stop adding a favorite" : "Add favorite")
            }
            .padding(.leading, 12)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { overMaps["\(city.rawValue) side"] = $0 }
        }
    }

    /// The +: a picker after the favorites, and there; again (the ✕), back to the favorite.
    private func toggleAdding(in city: City) {
        if addingIn == city {
            Journey.shared.tap("picker.close", "side")
            let back = isFavorite(selection) && selection.city == city ? selection.id : favorites.last { $0.city == city }?.id
            if let back { go(to: back, in: city) }
            // Once it's out of sight.
            Task {
                try? await Task.sleep(for: .seconds(0.5))
                if reels[city] != Self.pickerPage { addingIn = nil }
            }
        } else {
            Journey.shared.tap("favorite.add", Journey.from("side"))
            addingIn = city
            // Once it's there to scroll to.
            Task {
                try? await Task.sleep(for: .milliseconds(50))
                go(to: Self.pickerPage, in: city)
            }
        }
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

    /// Where the ring down the side is, in circles: following the pages as they're swiped (from iOS 18),
    /// else on the one showing.
    private func progress(in city: City, shown: String?, of cityFavorites: [Selection]) -> CGFloat {
        if let swiped = reelProgress[city] { return max(swiped, 0) }
        return CGFloat(cityFavorites.firstIndex { $0.id == shown } ?? 0)
    }

    /// The city's favorites, a circle each, the one showing ringed. As many as fit in their share
    /// of the screen; past that, a slice of the next shows, and the column scrolls.
    private func favoritesColumn(_ cityFavorites: [Selection], shown: String?, in city: City) -> some View {
        let step = Self.storySize + Self.storyGap
        let room = max(screenHeight * Self.sideShare, step)
        let fit = max(Int((room - Self.storyGap) / step), 1)
        let height = cityFavorites.count <= fit
            ? CGFloat(cityFavorites.count) * step + Self.storyGap
            : CGFloat(fit) * step + Self.storyGap + Self.storySize * 0.4
        return ScrollViewReader { scroller in
            ScrollView(.vertical) {
                VStack(spacing: Self.storyGap) {
                    ForEach(cityFavorites) { favorite in
                        story(favorite, in: city)
                    }
                }
                .padding(.vertical, Self.storyGap)
                // The one showing, ringed: the ring slides along under the circles as the pages are swiped.
                .background(alignment: .top) {
                    let at = progress(in: city, shown: shown, of: cityFavorites)
                    Circle()
                        .strokeBorder(LineBadge.red, lineWidth: 3)
                        // In the room around each circle's dark middle, where its own faint ring is.
                        .frame(width: Self.storySize, height: Self.storySize)
                        .offset(y: Self.storyGap + min(at, CGFloat(cityFavorites.count - 1)) * step)
                        // Fading out on the way to the picker after the last.
                        .opacity(sideDrag?.city == city ? 0 : 1 - min(max(at - CGFloat(cityFavorites.count - 1), 0) * 2, 1))
                        .animation(.smooth(duration: 0.25), value: shown)
                }
            }
            .scrollIndicators(.hidden)
            .frame(width: Self.sideWidth, height: height)
            .glass(in: Capsule())
            .clipShape(Capsule())
            .environment(\.colorScheme, .dark)
            // The one showing kept in view as the pages are swiped.
            .onChange(of: shown) {
                guard let shown, cityFavorites.contains(where: { $0.id == shown }) else { return }
                withAnimation(.smooth(duration: 0.3)) { scroller.scrollTo(shown) }
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
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { storyFrames[favorite.id] = $0 }
            .onTapGesture {
                Journey.shared.tap("favorite.open", "side")
                go(to: favorite.id, in: city)
            }
            .gesture(LongPressGesture(minimumDuration: 0.4)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
                .onChanged { value in
                    guard case .second(true, let drag) = value else { return }
                    if sideDrag == nil { pickUp(favorite, in: city) }
                    if let drag { moveHeld(to: drag.location) }
                }
                .onEnded { _ in dropHeld() })
            .id(favorite.id)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("\(favorite.lineLabel) at \(favorite.stopName)")
            .accessibilityAction { go(to: favorite.id, in: city) }
    }

    struct SideDrag {
        let city: City
        var order: [String]
        let held: String
    }

    private func pickUp(_ favorite: Selection, in city: City) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Journey.shared.tap("favorite.hold", "side")
        withAnimation(.snappy(duration: 0.2)) {
            sideDrag = SideDrag(city: city, order: favorites.filter { $0.city == city }.map(\.id), held: favorite.id)
        }
    }

    /// The held favorite takes the place of the one the finger is over, the others making way.
    private func moveHeld(to at: CGPoint) {
        guard var moving = sideDrag,
              let over = moving.order.first(where: { $0 != moving.held && storyFrames[$0].map { ($0.minY...$0.maxY).contains(at.y) } == true }),
              let from = moving.order.firstIndex(of: moving.held), let to = moving.order.firstIndex(of: over) else { return }
        moving.order.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.snappy(duration: 0.25)) { sideDrag = moving }
    }

    /// Let go of: the city's favorites in their new order (the others' as they were).
    private func dropHeld() {
        guard let moving = sideDrag else { return }
        if favorites.filter({ $0.city == moving.city }).map(\.id) != moving.order {
            Journey.shared.tap("favorite.reorder", "side")
            // The page showing stays, wherever it's moved to: the pages would otherwise stay where they
            // are, on whichever favorite took its place.
            let keep = reel(in: moving.city).wrappedValue
            favorites = favorites.filter { $0.city != moving.city } + moving.order.compactMap { id in favorites.first { $0.id == id } }
            if let keep {
                Task {
                    try? await Task.sleep(for: .milliseconds(50))
                    reel(in: moving.city).wrappedValue = keep
                }
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
        withAnimation(.smooth(duration: 0.4)) { reel(in: city).wrappedValue = page }
    }

    /// A favorite, over the whole screen: its route and buses, and over the bottom, what and when, with
    /// what to do with it along the right.
    private func reel(_ favorite: Selection) -> some View {
        let id = favorite.id
        return HomeMap(city: favorite.city, open: favorite, feed: feed, topInset: routeTop(favorite.city),
                       bottomInset: Self.captionRoom + insets.bottom, leadingInset: routeLeading(favorite.city), gesture: mapGesture?.page == id ? mapGesture?.gesture : nil)
            .overlay {
                MapTouches(onGesture: { gesture in mapGesture = gesture.map { (id, $0) } },
                           onHold: { hold($0, favorite) }, ignores: { isOverMap($0, in: favorite.city) })
            }
            .overlay(alignment: .bottom) { caption(favorite) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(favorite.lineLabel) to \(favorite.destination)")
    }

    /// The city's stop picker, after its favorites (or alone, before there are any): a stop picked there
    /// joins them, and opens.
    private func pickerReel(_ city: City, first: Bool) -> some View {
        let id = "\(city.rawValue) \(Self.pickerPage)"
        return HomeMap(city: city, picking: true, opened: true, topInset: insets.top + 120, bottomInset: insets.bottom,
                       gesture: mapGesture?.page == id ? mapGesture?.gesture : nil, tap: pickerTaps[city], onPick: picked)
            .id(pickerRounds[city] ?? 0)
            .overlay {
                MapTouches(onGesture: { gesture in mapGesture = gesture.map { (id, $0) } }, ignores: { isOverMap($0, in: city) }, onTap: { spot in
                    guard pickerRails[city]?.contains(spot) != true,
                          !overMaps.contains(where: { $0.key.hasPrefix(city.rawValue) && $0.value.contains(spot) }) else { return }
                    pickerTaps[city] = MapTap(location: spot)
                })
            }
            .overlay(alignment: .top) {
                if first {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Where do you wait?").font(.headline)
                        Text("Tap a line, then your stop, and watch the \(city.vehicles) not come, live. Your stops land here, one after another, and on your widgets.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
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
                    railButton("lock.iphone", label: "Put your \(city.vehicles) on the Lock Screen") {
                        Journey.shared.tap("guide.open")
                        showingGuide = true
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
    private func caption(_ favorite: Selection) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 0) {
                        openFavoriteCard(favorite)
                            .offset(y: favorite.id == selection.id ? pillNudge : 0)
                            .task { if favorite.id == selection.id { await nudgePill() } }
                        Spacer(minLength: 0)
                    }
                    details(favorite)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                railButton("paperplane", label: "Share this stop") {
                    Journey.shared.tap("share.open", Journey.from("map"))
                    sharingFrom = "map"
                    sharing = favorite
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
    }

    /// A map held, and moved, and let go of: zoomed out to the city's favorites, to move it among them.
    private func hold(_ event: MapTouches.Hold, _ favorite: Selection) {
        switch event {
        case .began(let at):
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            Journey.shared.tap("favorite.hold")
            withAnimation(.smooth(duration: 0.35)) {
                reordering = Reordering(city: favorite.city, order: favorites.filter { $0.city == favorite.city }.map(\.id),
                                        held: favorite.id, at: at)
            }
        case .moved(let at): drag(to: at)
        case .ended: drop()
        }
    }

    /// The held favorite under the finger: it takes the place of the one it's over, the others making way.
    private func drag(to at: CGPoint) {
        guard var moving = reordering, let held = moving.held else { return }
        moving.at = at
        if let over = moving.order.first(where: { $0 != held && cellFrames[$0]?.contains(at) == true }),
           let from = moving.order.firstIndex(of: held), let to = moving.order.firstIndex(of: over) {
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
    private func grid(_ moving: Reordering) -> some View {
        GeometryReader { geometry in
            let screen = geometry.size
            let gap: CGFloat = 12
            let top = insets.top + 56, bottom = insets.bottom + 110
            let shown = moving.order.compactMap { id in favorites.first { $0.id == id } }
            // Two to a row if they fit, else more.
            let columns = (2...4).first { columns in
                let width = (screen.width - gap * CGFloat(columns + 1)) / CGFloat(columns)
                let rows = (shown.count + columns - 1) / columns
                return CGFloat(rows) * (width * screen.height / screen.width + gap) <= screen.height - top - bottom
            } ?? 4
            let width = (screen.width - gap * CGFloat(columns + 1)) / CGFloat(columns)
            let scale = width / screen.width
            let rows = (shown.count + columns - 1) / columns
            // In the middle of the room for them.
            let tall = CGFloat(rows) * (width * screen.height / screen.width + gap) - gap
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
                .padding(.top, max(top, top + (screen.height - top - bottom - tall) / 2))
                // The one held, under the finger, and the bin to drop it on.
                if let held = moving.held, let favorite = favorites.first(where: { $0.id == held }) {
                    heldCard(favorite, at: moving.at, screen: screen, scale: scale)
                    bin(over: binFrame.contains(moving.at), screen: screen)
                }
            }
        }
        .ignoresSafeArea()
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
        HomeMap(city: favorite.city, open: favorite, topInset: insets.top + 120, bottomInset: insets.bottom + 60)
            .frame(width: screen.width, height: screen.height)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: screen.width * scale, height: screen.height * scale, alignment: .topLeading)
            .allowsHitTesting(false)
            // As on its page, though the grid around it is dark.
            .environment(\.colorScheme, colorScheme)
            .overlay(alignment: .bottomLeading) {
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
                .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
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

    /// A stop picked, on the map or from the lines by number: it joins the favorites (at the end) and opens.
    private func picked(_ picked: Selection) {
        if !favorites.contains(where: { $0.id == picked.id }) {
            favorites.append(picked)
            Journey.shared.tap("favorite.added", Journey.from("picker"))
        }
        Journey.shared.tap("stop.open", Journey.from("picker"))
        searchingLines = false
        show(picked)
        // A fresh picker for next time, once it's out of sight.
        Task {
            try? await Task.sleep(for: .seconds(0.8))
            pickerRounds[picked.city, default: 0] += 1
            if addingIn == picked.city { addingIn = nil }
        }
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

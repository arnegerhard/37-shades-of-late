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

struct ContentView: View {
    @State private var selection = Selection.current
    @State private var feed = DepartureFeed()
    @State private var favoritesFeed = FavoritesFeed()
    @Environment(\.scenePhase) private var scenePhase
    @State private var choosing = false
    /// Whether the stop picked next is saved as a favorite (the + by Favorites), or only shown on the
    /// map to try (the map's Find a stop), with a + by its pill to save it after all.
    @State private var choosingFavorite = true
    /// The stop picked to try, not (yet) a favorite: on the map until another opens.
    @State private var trying: Selection?
    /// Whether the + to keep it has calmed down to a quiet outline: a few seconds after it shows, or
    /// once the map is touched. It stays, so it never goes away under a thumb, but stops asking.
    @State private var plusQuiet = false
    @State private var pickerPath: [Line] = []
    @Namespace private var mapZoom
    /// The stop being shared, from the home map.
    @State private var sharing: Selection?
    /// Where the share was opened, for Journey: "map" (the map's button) or "favorite" (a row's menu).
    @State private var sharingFrom = "map"
    /// A stop from a shared link, waiting for "Add".
    @State private var incoming: Selection?
    /// Who shared the incoming stop (see Selection.sharer), for Journey.
    @State private var sharedBy: String?
    @State private var favorites = Selection.favorites
    /// The widget walkthrough again (screenshot runs; the first launch's is `Welcome`).
    @State private var showingGuide = false
    /// The cities shown, with a page each (see `City.chosen`), and whether their map is up to change them.
    @State private var cities = City.chosen
    @State private var choosingCities = false
    /// How far each city's list is scrolled; the hint and city picker slide away by as much (up to
    /// their own height) to give the pinned map their room.
    @State private var scrollOffsets: [City: CGFloat] = [:]
    @State private var headerHeight: CGFloat = 0
    /// The height of a city's page, for the map's share of it.
    @State private var pageHeight: CGFloat = 0
    /// Each city's list, which takes one finger's touches on the map above it (see `MapTouches`).
    @State private var lists: [City: ListScrollView] = [:]
    /// The cities whose list has been scrolled to hide the city picker (see `hideHeader`).
    @State private var headerHidden: Set<City> = []
    /// Each city's list's resting place, with the picker out of view (see `HeaderRest`).
    @State private var headerRests: [City: HeaderRest] = [:]
    /// Two fingers moving the open city's map, as they go (see `MapTouches`).
    @State private var mapGesture: MapGesture?
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
                // The 37 as the app icon has it: white on the red, in a rounded box.
                HStack(spacing: 8) {
                    Text("37")
                        .font(.system(.largeTitle, design: .rounded).weight(.heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .background(LineBadge.red, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Text("Shades of Late")
                        .font(.largeTitle.bold())
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("37 Shades of Late")
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                    .accessibilityAddTraits(.isHeader)
                // A page per city, each with its own map, open stop and favorites; swiping anywhere
                // switches city and the page slides along. The hint and city picker stay put above
                // the pages (each page leaves room for them), sliding up only as the list scrolls.
                ZStack(alignment: .top) {
                    TabView(selection: Binding(get: { selection.city }, set: { switchCity(to: $0, from: "swipe") })) {
                        ForEach(shownCities) { city in
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
            .journeyScreen("home")
            .onAppear { Journey.shared.setCity(selection.city.rawValue) }
            // Only a favorite's times are shown on the home screen, or the stop being tried.
            .task(id: isShown(selection) ? selection : nil) {
                if isShown(selection) { await feed.follow(selection) }
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
                // A widget tap: that line and stop on the home map.
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
                        select(picked)
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
                case .lines: choosing = true
                case .cities: choosingCities = true
                case .stops:
                    // As from the map's Find a stop: the stop picked is only shown, to try.
                    choosingFavorite = false
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
            .sheet(item: $sharing) { stop in
                ShareSheet(selection: stop, departures: shownDepartures(for: stop).departures, from: sharingFrom)
            }
            // The line picker grows out of the home map.
            .fullScreenCover(isPresented: $choosing) {
                NavigationStack(path: $pickerPath) {
                    LinePicker { picked in
                        // From the +, picking a stop saves it: it joins the favorites (at the end) and
                        // opens. From the map, it only opens, to try.
                        if !favorites.contains(where: { $0.id == picked.id }) {
                            if choosingFavorite {
                                favorites.append(picked)
                                Journey.shared.tap("favorite.added", Journey.from("plus"))
                            } else {
                                trying = picked
                                Selection.remember(picked)
                            }
                        }
                        Journey.shared.tap("stop.open", Journey.from(choosingFavorite ? "plus" : "find"))
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
                WidgetGuide { showingGuide = false }
            }
            .sheet(isPresented: $choosingCities) {
                CityChooser {
                    choosingCities = false
                    setCities(City.chosen)
                }
            }
        }
    }

    /// One city: the map showing its open favorite and the city's favorites (+ picks another stop).
    /// Before there are any, the map shows the city's main lines and the list says how it all works.
    private func cityPage(_ city: City) -> some View {
        let open = preview(for: city)
        let cityFavorites = favorites.filter { $0.city == city }
        let openIsFavorite = cityFavorites.contains { $0.id == open.id }
        let openIsShown = isShown(open)
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
                            Text("Find a stop on the map to watch the \(city.vehicles) not come, live, or tap + to keep one and start curating your suffering in \(city.endingSentence) Your stops land here and on your widgets.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    ForEach(cityFavorites) { favorite in
                        // Tapping a favorite opens it on the map above; holding it offers to share or
                        // delete it, and holding the handle drags it to reorder.
                        HStack(spacing: 8) {
                            Button {
                                Journey.shared.tap("favorite.open", favorite.id == selection.id ? "already" : nil)
                                if favorite.id != selection.id { Journey.shared.tap("stop.open", Journey.from("favorite")) }
                                select(favorite)
                            } label: { favoriteRow(favorite) }
                            .buttonStyle(.borderless)
                            .tint(.primary)
                            .contextMenu {
                                Button { Journey.shared.tap("share.open", Journey.from("favorite")); sharingFrom = "favorite"; sharing = favorite } label: {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                                // Deletes at once: it's only a favorite, and adding it back takes a moment.
                                Button(role: .destructive) {
                                    Journey.shared.tap("favorite.delete")
                                    withAnimation { favorites.removeAll { $0.id == favorite.id } }
                                    Selection.remember(favorite)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.tertiary)
                                .frame(width: 20, height: 44)
                                .contentShape(Rectangle())
                                .accessibilityHidden(true)
                        }
                        .listRowBackground(favoriteBackground(isSelected: favorite.id == open.id))
                        // Not the list's own swipe to delete: a sideways swipe on a row turns the page.
                        .deleteDisabled(true)
                    }
                    .onMove { from, to in
                        Journey.shared.tap("favorite.reorder")
                        // Only this city's order changes; each city keeps its own list.
                        var reordered = cityFavorites
                        reordered.move(fromOffsets: from, toOffset: to)
                        favorites = favorites.filter { $0.city != city } + reordered
                    }
                } header: {
                    HStack(spacing: 0) {
                        Text("Favorites")
                        // White on the page's gray (the rows' color, so dark in dark mode), the plus in the
                        // 37's red: the one thing to do here, next to what it adds to.
                        Button { Journey.shared.tap("favorite.add", Journey.from("plus")); choosingFavorite = true; choosing = true } label: {
                            Image(systemName: "plus")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(LineBadge.red)
                                .frame(width: 30, height: 30)
                                .background(Color(.secondarySystemGroupedBackground), in: Circle())
                                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                                // A finger-sized target around the smaller circle.
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.borderless)
                        .padding(.vertical, -10)
                        .padding(.leading, 2)
                        .accessibilityLabel("Add favorite")
                        Spacer()
                    }
                    .textCase(nil)
                    // Finds the list it's in, for the map above to scroll (see `MapTouches`).
                    .background(ListScrollView.Finder { lists[city] = $0; hideHeader(city) })
                    // Under the tall map, until scrolled away.
                    .padding(.top, tallMap(city) - Self.shortMap)
                } footer: {
                    // The Lock Screen button lives in the favorites' footer rather than a section of its
                    // own: a favorite dragged past the last row would otherwise land in that section,
                    // where it can't go, and snap back instead of moving to the end.
                    VStack(alignment: .leading, spacing: 10) {
                        if !cityFavorites.isEmpty {
                            Text("When you're in \(city.name), your widgets suffer in this order; the small ones only have room for the top one. Hold one to share or delete it, or its handle to drag it into place.")
                        }
                        Button { Journey.shared.tap("guide.open"); showingGuide = true } label: {
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
                    .frame(height: tallMap(city) - shrink(city))
                    .overlay(alignment: .bottom) {
                        Group {
                            // The gesture is in the visible part's points; the map's top is cut off by its shrink.
                            let gesture = city == selection.city ? mapGesture?.moved(down: shrink(city)) : nil
                            if openIsShown {
                                RouteMap(selection: open, feed: feed, topInset: 44, cropped: restingShrink[city] ?? 0, gesture: gesture)
                            } else {
                                CityLinesMap(city: city, gesture: gesture)
                            }
                        }
                        .frame(height: tallMap(city))
                        .allowsHitTesting(false)
                    }
                    .task(id: shrink(city)) {
                        let shrunk = shrink(city)
                        try? await Task.sleep(for: .milliseconds(250))
                        if !Task.isCancelled { restingShrink[city] = shrunk }
                    }
                    // One finger on the map goes to the list it sits over, so dragging it scrolls the
                    // favorites just as the list does (bounce and all), and sideways still turns the page.
                    // Two fingers move the map: pinch to zoom, drag to pan.
                    .overlay {
                        MapTouches(list: lists[city]) { gesture in
                            mapGesture = gesture
                            if gesture != nil, !plusQuiet { withAnimation(.easeInOut(duration: 0.3)) { plusQuiet = true } }
                        }
                    }
                    .accessibilityLabel(openIsShown ? "Map, \(open.lineLabel) to \(open.destination)" : "\(city.name)'s main lines")
                    .overlay(alignment: .topLeading) {
                        if openIsShown {
                            HStack(spacing: 8) {
                                openFavoriteCard(open)
                                    .offset(y: pillNudge)
                                    .task { await nudgePill() }
                                    .layoutPriority(1)
                                // A stop being tried, kept with one tap.
                                if !openIsFavorite {
                                    Button {
                                        Journey.shared.tap("favorite.added", Journey.from("pill"))
                                        withAnimation { favorites.append(open) }
                                        trying = nil
                                    } label: {
                                        Image(systemName: "plus")
                                            .font(plusQuiet ? .caption.weight(.semibold) : .subheadline.weight(.bold))
                                            .foregroundStyle(plusQuiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(LineBadge.red))
                                            .frame(width: plusQuiet ? 26 : 34, height: plusQuiet ? 26 : 34)
                                            .background {
                                                if plusQuiet {
                                                    Circle().fill(.ultraThinMaterial)
                                                        .overlay(Circle().strokeBorder(.secondary, lineWidth: 1))
                                                } else {
                                                    Circle().fill(Color(.secondarySystemGroupedBackground))
                                                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                                                }
                                            }
                                            // A finger-sized target whatever its size.
                                            .frame(width: 44, height: 44)
                                            .contentShape(Circle())
                                    }
                                    .buttonStyle(.borderless)
                                    .padding(.horizontal, -5)
                                    .accessibilityLabel("Add to favorites")
                                    .transition(.scale.combined(with: .opacity))
                                    .task(id: open.id) {
                                        plusQuiet = false
                                        try? await Task.sleep(for: .seconds(4))
                                        if !Task.isCancelled { withAnimation(.easeInOut(duration: 0.5)) { plusQuiet = true } }
                                    }
                                }
                            }
                            .padding(10)
                            // Clear of the find button.
                            .padding(.trailing, 48)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        // Any stop, to see it on the map without keeping it.
                        Button { Journey.shared.tap("stop.find", Journey.from("map")); choosingFavorite = false; choosing = true } label: {
                            Group {
                                if openIsShown {
                                    Image(systemName: "magnifyingglass")
                                        .frame(width: 38, height: 38)
                                } else {
                                    Label("Find a stop", systemImage: "magnifyingglass")
                                        .padding(.horizontal, 14)
                                        .frame(height: 38)
                                }
                            }
                            .font(.subheadline.weight(.semibold))
                            .background(.regularMaterial, in: Capsule())
                        }
                        .buttonStyle(.borderless)
                        .padding(10)
                        .accessibilityLabel("Find a stop")
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if openIsShown {
                            Button { Journey.shared.tap("share.open", Journey.from("map")); sharingFrom = "map"; sharing = open } label: {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(width: 38, height: 38)
                                    .background(.regularMaterial, in: Circle())
                            }
                            .buttonStyle(.borderless)
                            // Clear of the refresh bar along the bottom.
                            .padding(10)
                            .padding(.bottom, 3)
                            .accessibilityLabel("Share this stop")
                        }
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
            HStack(spacing: 10) {
                if shownCities.count > 1 {
                    Picker("City", selection: Binding(get: { selection.city }, set: { switchCity(to: $0, from: "tabs") })) {
                        // Five or more don't fit by name next to the pencil: by their codes, as on the widgets.
                        ForEach(shownCities) { Text(shownCities.count > 4 ? $0.code : $0.shortName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } else {
                    Text(selection.city.name)
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button { Journey.shared.tap("cities.edit"); choosingCities = true } label: {
                    Image(systemName: "pencil")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .tint(.secondary)
                .accessibilityLabel("Choose cities")
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { height in
            headerHeight = height
            for rest in headerRests.values { rest.header = height }
        }
    }

    /// The map's height before the list scrolls: three quarters of the page, the favorites below it.
    private func tallMap(_ city: City) -> CGFloat {
        max(Self.shortMap, (pageHeight * 3 / 4).rounded())
    }
    /// How small the map gets with the list scrolled.
    private static let shortMap: CGFloat = 260

    /// How far the header has slid away for `city`: as far as its list is scrolled, up to its height.
    /// It goes first, and starts out gone (see `hideHeader`): most people stay in one city.
    private func collapse(_ city: City) -> CGFloat {
        min(max(scrollOffsets[city] ?? 0, 0), headerHeight)
    }

    /// How much the map has shrunk for `city`: as far as its list is scrolled past the header's
    /// sliding away, down to the short map.
    private func shrink(_ city: City) -> CGFloat {
        min(max((scrollOffsets[city] ?? 0) - headerHeight, 0), tallMap(city) - Self.shortMap)
    }

    /// Scrolls `city`'s list just far enough to slide the city picker away, the first time it shows:
    /// pulling the list down brings it back.
    private func hideHeader(_ city: City) {
        guard let view = lists[city]?.view else { return }
        if headerRests[city]?.view !== view { headerRests[city] = HeaderRest(view) }
        headerRests[city]?.header = headerHeight
        guard !headerHidden.contains(city), headerHeight > 0 else { return }
        headerHidden.insert(city)
        view.setContentOffset(CGPoint(x: view.contentOffset.x, y: -view.adjustedContentInset.top + headerHeight), animated: false)
    }

    /// Whether `stop` is on its city's map: a favorite, or the stop being tried.
    private func isShown(_ stop: Selection) -> Bool {
        stop.id == trying?.id || favorites.contains { $0.id == stop.id }
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
                    LineBadges(parts: favorite.badgeParts, font: .system(.subheadline, design: .rounded).weight(.heavy), round: favorite.roundBadge)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .layoutPriority(1)
                    Text("To \(favorite.destination)").font(.subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                    Group {
                        if upcoming.isEmpty {
                            Text(loaded == nil ? "…" : "none")
                        } else {
                            WaitsLabel(departures: upcoming, date: context.date, count: 1, selection: favorite,
                                       badgeFont: .system(.footnote, design: .rounded).weight(.heavy))
                        }
                    }
                        .font(.system(.headline, design: .rounded).weight(.semibold))
                        .foregroundStyle(upcoming.first?.isLive == true ? .green : .secondary)
                        .monospacedDigit()
                        .fixedSize()
                }
                HStack(spacing: 8) {
                    Text(favorite.stopName).font(.footnote).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if upcoming.count > 1 {
                        WaitsLabel(departures: Array(upcoming.dropFirst()), date: context.date, count: 2, selection: favorite,
                                   unit: false, badgeFont: .system(size: 9, weight: .heavy, design: .rounded))
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
    /// island), or takes it off again.
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
                    .frame(height: 34)
            }
        }
        .buttonStyle(.plain)
        // Without Live Activities (turned off in Settings) there's nowhere for it to go.
        .disabled(!canWatch)
        .popoverTip(StalkTip(island: Island.frame != nil), arrowEdge: .top)
        .accessibilityLabel("\(open.lineLabel) at \(open.stopName)")
        .accessibilityHint(!canWatch ? ""
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

    /// Opens the line a widget row showed on the home map, over whatever was on screen.
    /// `on`: where it was tapped, "home", "lock", "activity" or "island" (see `URL.tapped(on:)`).
    private func openFromWidget(_ tapped: Selection, on place: String?) {
        Journey.shared.tap("widget.open", place)
        Journey.shared.tap("stop.open", Journey.from(place.map { "widget \($0)" } ?? "widget"))
        choosing = false
        sharing = nil
        select(tapped)
    }

    private func takeWidgetTap() {
        if let link = WidgetTap.take(), let tapped = Selection(openURL: link) { openFromWidget(tapped, on: link.tappedOn) }
    }

    /// Makes `picked` the line and stop shown in the app.
    private func select(_ picked: Selection) {
        guard picked.id != selection.id else { return }
        Selection.current = picked
        Journey.shared.setCity(picked.city.rawValue)
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
    /// The cities with a page: the chosen ones, and the open one should it not be (a widget's tap,
    /// before the welcome map's Done).
    private var shownCities: [City] { City.allCases.filter { cities.contains($0) || $0 == selection.city } }

    /// Saves which cities to show; when the open one is left out, the first one left opens.
    private func setCities(_ chosen: [City]) {
        City.chosen = chosen
        cities = City.chosen
        if !cities.contains(selection.city), let first = cities.first { switchCity(to: first, from: "cities") }
    }

    /// `from`: how, for Journey: "swipe", "tabs", or "cities" (the open one left out on the map of them).
    private func switchCity(to city: City, from: String) {
        guard city != selection.city else { return }
        Journey.shared.tap("city.switch", "\(city.rawValue), \(Journey.from(from))")
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

/// The line picker grows out of the home map and shrinks back into it (iOS 18; before, it slides in
/// as usual).
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

/// The home map the line picker zooms out of and back into.
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

/// A list's scroll view, found from a view in the list (`Finder`), held weakly.
struct ListScrollView {
    weak var view: UIScrollView?

    struct Finder: UIViewRepresentable {
        let found: (ListScrollView) -> Void

        func makeUIView(context: Context) -> FinderView {
            let view = FinderView()
            view.found = found
            return view
        }

        func updateUIView(_ view: FinderView, context: Context) { view.found = found }
    }

    final class FinderView: UIView {
        var found: ((ListScrollView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            var view = superview
            while let next = view, !(next is UIScrollView) { view = next.superview }
            guard let scrollView = view as? UIScrollView else { return }
            // Not during the update that put this here.
            DispatchQueue.main.async { [found] in found?(ListScrollView(view: scrollView)) }
        }
    }
}

/// The home map's touches. One finger's go to the list under it: whatever its scroll view (and the
/// pages around it) make of them, as if the map were the top of the list. Two fingers on the map
/// move it instead, through `onGesture`; meanwhile the list and the pages hold still.
///
/// The two-finger gestures watch the whole window, not the list: UIKit hands a touch to the view
/// it lands on, and SwiftUI doesn't land a second finger on the list the first one went to.
private struct MapTouches: UIViewRepresentable {
    let list: ListScrollView?
    let onGesture: (MapGesture?) -> Void

    func makeUIView(context: Context) -> Forwarder { Forwarder() }

    func updateUIView(_ view: Forwarder, context: Context) {
        view.onGesture = onGesture
        view.list = list?.view
    }

    final class Forwarder: UIView, UIGestureRecognizerDelegate {
        var onGesture: ((MapGesture?) -> Void)?
        weak var list: UIScrollView?
        private lazy var pinch = recognizer(UIPinchGestureRecognizer(target: self, action: #selector(moved)))
        private lazy var pan: UIPanGestureRecognizer = {
            let pan = recognizer(UIPanGestureRecognizer(target: self, action: #selector(moved)))
            pan.minimumNumberOfTouches = 2
            return pan
        }()
        /// The list and the pages around it, and where they were as the fingers came down: held there
        /// while two fingers move the map, as the first may have started scrolling them.
        private var held: [(view: UIScrollView, offset: CGPoint)] = []
        private var start: CGPoint?

        private func recognizer<T: UIGestureRecognizer>(_ recognizer: T) -> T {
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesEnded = false
            return recognizer
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            pinch.view?.removeGestureRecognizer(pinch)
            pan.view?.removeGestureRecognizer(pan)
            window?.addGestureRecognizer(pinch)
            window?.addGestureRecognizer(pan)
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard self.point(inside: point, with: event) else { return nil }
            return list ?? self
        }

        /// Only touches on this map, on the page that's showing.
        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard bounds.contains(touch.location(in: self)) else { return false }
            // The first finger down: where everything is, before it scrolls anything.
            if gesture === pinch, pinch.numberOfTouches == 0 {
                held = []
                var view: UIView? = list
                while let current = view {
                    if let scrollView = current as? UIScrollView { held.append((scrollView, scrollView.contentOffset)) }
                    view = current.superview
                }
            }
            return true
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        @objc private func moved(_ gesture: UIGestureRecognizer) {
            switch gesture.state {
            case .began:
                // Turning a scroll view's pan off and on again stops whatever it had started.
                for (view, offset) in held {
                    view.panGestureRecognizer.isEnabled = false
                    view.setContentOffset(offset, animated: false)
                }
                if start == nil { start = gesture.location(in: self) }
                report()
            case .changed:
                report()
            default:
                // Both end; the gesture is over once neither is going.
                guard ![pinch, pan].contains(where: { $0.state == .began || $0.state == .changed }) else { return }
                held.forEach { $0.view.panGestureRecognizer.isEnabled = true }
                held = []
                start = nil
                onGesture?(nil)
            }
        }

        private func report() {
            guard let start else { return }
            let going = pan.state == .began || pan.state == .changed
            onGesture?(MapGesture(scale: pinch.state == .began || pinch.state == .changed ? pinch.scale : 1,
                                  translation: going ? pan.translation(in: self) : .zero, start: start))
        }

        deinit {
            pinch.view?.removeGestureRecognizer(pinch)
            pan.view?.removeGestureRecognizer(pan)
        }
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
/// Scrolling back up runs on past the city picker, showing it on the way, but the list comes to rest
/// with it just out of view, as it starts out (see `hideHeader`). A pull from there brings it in to
/// stay; let go partway, it goes the way it was going. SwiftUI's lists don't take scroll targets, so
/// this watches the list's own pan and steers it.
final class HeaderRest: NSObject {
    weak var view: UIScrollView?
    /// The picker's height: how far the list rests from its top.
    var header: CGFloat = 0
    /// How far the list was scrolled as the drag began.
    private var start: CGFloat = 0

    init(_ view: UIScrollView) {
        self.view = view
        super.init()
        view.panGestureRecognizer.addTarget(self, action: #selector(panned))
    }

    private var offset: CGFloat { view.map { $0.contentOffset.y + $0.adjustedContentInset.top } ?? 0 }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard header > 0 else { return }
        if pan.state == .began { start = offset }
        guard pan.state == .ended, let view else { return }
        if start > header + 1 {
            // From further down (not from its resting place): let it coast, then tuck the picker away if
            // it stopped on it.
            settle()
            return
        }
        // Pulled past the top, it's the list's own pull to refresh.
        guard offset >= 0, offset < header else { return }
        let velocity = pan.velocity(in: view).y
        let rest: CGFloat = velocity > 50 || (abs(velocity) <= 50 && offset < header / 2) ? 0 : header
        // After UIKit has started coasting, which this replaces.
        DispatchQueue.main.async { self.glide(to: rest) }
    }

    /// Once the list stops, back to its resting place if it came to rest with the picker showing.
    private func settle() {
        Task { @MainActor [weak self] in
            while let view = self?.view, view.isDecelerating || view.isTracking {
                if view.isTracking { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let self, offset >= 0, offset < header else { return }
            glide(to: header)
        }
    }

    private func glide(to rest: CGFloat) {
        guard let view else { return }
        view.setContentOffset(CGPoint(x: view.contentOffset.x, y: rest - view.adjustedContentInset.top), animated: true)
    }
}

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

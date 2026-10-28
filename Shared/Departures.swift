import Foundation

/// A city the proxy has live data for.
enum City: String, Codable, CaseIterable, Identifiable {
    case sf, seattle, nyc

    var id: String { rawValue }

    var name: String {
        switch self {
        case .sf: "San Francisco"
        case .seattle: "Seattle"
        case .nyc: "New York"
        }
    }

    /// Short tag for tight spaces like widgets, where lines from two cities sit side by side.
    var code: String {
        switch self {
        case .sf: "SF"
        case .seattle: "SEA"
        case .nyc: "NYC"
        }
    }

    /// What mostly runs here, for the page's wording; a stop's own is `Selection.vehicle`.
    var vehicle: String { self == .nyc ? "train" : "bus" }
    var vehicles: String { self == .nyc ? "trains" : "buses" }

    /// Where this city's endpoints live on the proxy; SF predates the others and has no prefix.
    fileprivate var pathPrefix: String {
        switch self {
        case .sf: ""
        case .seattle: "seattle/"
        case .nyc: "nyc/"
        }
    }

    /// What a new install shows before anything has been picked.
    var defaultSelection: Selection {
        switch self {
        case .sf:
            // Inbound 37 Corbett toward the Haight at 14th St & Church St, one block from Market & Church.
            Selection(lineID: "37", lineName: "Corbett", directionID: "IB", destination: "Masonic + Haight",
                      stopCode: "13254", stopName: "14th St & Church St")
        case .seattle:
            // The 8 toward Mount Baker on Denny Way, where it's famously late.
            Selection(lineID: "8", lineName: "Seattle Center - Capitol Hill - Rainier Beach", directionID: "1",
                      destination: "Mount Baker Transit Center", stopCode: "1_2260",
                      stopName: "Denny Way & Fairview Ave", city: .seattle)
        case .nyc:
            // The G toward Church Av at Metropolitan Av, where everyone waits for the shortest train in New York.
            Selection(lineID: "G", lineName: "Brooklyn-Queens Crosstown", directionID: "S", destination: "Church Av",
                      stopCode: "G29S", stopName: "Metropolitan Av", city: .nyc)
        }
    }
}

/// The line, direction and stop the user picked in the app. The widgets read it from the
/// shared App Group so they always show the same stop as the app.
struct Selection: Codable, Hashable, Identifiable {
    var lineID: String
    var lineName: String
    var directionID: String
    var destination: String
    var stopCode: String
    var stopName: String
    var city: City = .sf
    /// Other lines at the same stop the user is happy to take too, like the L and M besides the K
    /// at Castro toward downtown. Their departures are merged with the main line's.
    var also: [OtherLine] = []

    struct OtherLine: Codable, Hashable {
        var lineID: String
        /// Empty when the stop alone settles it (a nearby Seattle stop faces one way).
        var directionID: String
        /// Where to catch it when that's a nearby stop rather than this one.
        var stopCode: String? = nil
    }

    /// Every line this choice counts, the main one first.
    var lineIDs: [String] { [lineID] + also.map(\.lineID) }

    /// For badges and labels: "37", or "KLM" / "5·21" when several lines are combined.
    var lineLabel: String {
        let ids = lineIDs
        return ids.joined(separator: ids.allSatisfy { $0.count == 1 } ? "" : "·")
    }

    var isMultiLine: Bool { !also.isEmpty }

    /// "train", "bus" or "ferry": New York's bus stops are MTA Bus Time's ("MTA_308214"), its ferry
    /// landings NYC Ferry's or the Staten Island Ferry's ("NYCF_4", "SIF_stgeorge"), the rest of it rails;
    /// in San Francisco, BART's platforms ("M16-1") are trains.
    var vehicle: String {
        switch city {
        case .nyc: stopCode.hasPrefix("MTA_") ? "bus" : stopCode.hasPrefix("NYCF_") || stopCode.hasPrefix("SIF_") ? "ferry" : "train"
        case .sf: stopCode.wholeMatch(of: /[A-Z]\d+-\d/) != nil ? "train" : "bus"
        case .seattle: "bus"
        }
    }
    var vehicles: String {
        switch vehicle {
        case "bus": "buses"
        case "ferry": "ferries"
        default: "trains"
        }
    }

    /// The same lines, direction and stop count as one place, whatever the display names say.
    var id: String {
        let extra = also.map { "+\($0.lineID)/\($0.directionID)" + ($0.stopCode.map { "@\($0)" } ?? "") }.sorted().joined()
        return "\(city.rawValue)|\(lineID)|\(directionID)|\(stopCode)\(extra)"
    }

    static var defaultSelection: Selection { City.sf.defaultSelection }

    private static let key = "selection"
    private static let favoritesKey = "favorites"
    private static var defaults: UserDefaults { AppGroup.defaults }

    static var current: Selection {
        get {
            guard let data = defaults.data(forKey: key),
                  let selection = try? JSONDecoder().decode(Selection.self, from: data)
            else { return defaultSelection }
            return selection
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    /// False until the first line and stop is saved, e.g. on a fresh install.
    static var hasSavedChoice: Bool { defaults.data(forKey: key) != nil }

    /// The stop last open in each city, so switching back returns to it.
    static func lastOpened(in city: City) -> Selection? {
        defaults.data(forKey: "lastOpened-\(city.code)").flatMap { try? JSONDecoder().decode(Selection.self, from: $0) }
    }

    static func setLastOpened(_ selection: Selection) {
        defaults.set(try? JSONEncoder().encode(selection), forKey: "lastOpened-\(selection.city.code)")
    }

    /// What the widgets show: the favorites of the city you're in, in the order you arranged them,
    /// so a widget with room for one shows the top one. Without any there, the stop open in the app
    /// if it's in that city, else the favorites of the city open in the app, else just its open stop.
    static func widgetSelections(near city: City?) -> [Selection] {
        let favorites = favorites
        let current = current
        let here = favorites.filter { $0.city == city }
        if !here.isEmpty { return here }
        if current.city == city { return [current] }
        let open = favorites.filter { $0.city == current.city }
        return open.isEmpty ? [current] : open
    }

    /// Saved lines and stops, in the order the user arranged them.
    static var favorites: [Selection] {
        get {
            guard let data = defaults.data(forKey: favoritesKey),
                  let favorites = try? JSONDecoder().decode([Selection].self, from: data)
            else { return [] }
            return favorites
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: favoritesKey) }
    }
}

/// Settings shared between the app and its widgets.
enum AppGroup {
    static var defaults: UserDefaults { UserDefaults(suiteName: "group.info.jetsons.bus37") ?? .standard }

    /// A random ID this install made for itself, sent with requests so the proxy can count
    /// usage per install. It isn't tied to an account, Apple ID or any device identifier.
    static var installID: String {
        if let id = defaults.string(forKey: "installID") { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: "installID")
        return id
    }
}

/// Which part of the app made a request, for the proxy's usage statistics.
enum Client: String {
    case app, widget, map
}

extension Selection {
    /// Choices saved before Seattle existed have no city; they're all SF.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lineID = try container.decode(String.self, forKey: .lineID)
        lineName = try container.decode(String.self, forKey: .lineName)
        directionID = try container.decode(String.self, forKey: .directionID)
        destination = try container.decode(String.self, forKey: .destination)
        stopCode = try container.decode(String.self, forKey: .stopCode)
        stopName = try container.decode(String.self, forKey: .stopName)
        city = try container.decodeIfPresent(City.self, forKey: .city) ?? .sf
        also = try container.decodeIfPresent([OtherLine].self, forKey: .also) ?? []
    }
}

struct Departure: Hashable, Codable {
    let time: Date
    let isLive: Bool  // false when there's no bus assigned yet and the time is schedule-based
    var vehicle: Vehicle? = nil
    /// Which line this is, for choices that combine several lines.
    var line: String? = nil
}

extension Departure {
    /// Minutes until the next `count` departures, like "4 · 16 · 31 min" or "now · 9 min".
    /// With `lines`, each wait gets its line in front: "L 2 · K 5 · M 6 min".
    static func waits(_ departures: [Departure], from date: Date, count: Int, unit: Bool = true, lines: Bool = false) -> String? {
        let next = departures.filter { $0.time > date.addingTimeInterval(-30) }.prefix(count)
        guard !next.isEmpty else { return nil }
        let minutes = next.map { max(0, Int($0.time.timeIntervalSince(date) / 60)) }
        let parts = zip(next, minutes).map { departure, minutes in
            let wait = minutes == 0 ? "now" : "\(minutes)"
            return lines ? "\(departure.line ?? "") \(wait)".trimmingCharacters(in: .whitespaces) : wait
        }
        return parts.joined(separator: " · ") + (unit && minutes.last != 0 ? " min" : "")
    }
}

/// Where a live bus is right now, from its GPS.
struct Vehicle: Hashable, Codable {
    let lat: Double
    let lon: Double
    let bearing: Double?
}

struct Line: Hashable, Decodable, Identifiable {
    let id: String
    let name: String
    let mode: String
}

/// A line with its route shape, for picking lines on a map.
struct MapLine: Decodable, Identifiable {
    let id: String
    let name: String
    let mode: String
    /// Official GTFS route colors as "#RRGGBB", where the agency publishes them.
    let color: String?
    let textColor: String?
    /// [[lat, lon]] segments.
    let shapes: [[[Double]]]

    var line: Line { Line(id: id, name: name, mode: mode) }
}

/// A line serving a stop, as the proxy reports it from upcoming arrivals.
/// A line to also count at a stop: at the stop itself, or at another one a short walk away.
/// A stop on the map of every stop.
struct MapStop: Hashable, Decodable, Identifiable {
    let code: String
    let lat: Double
    let lon: Double
    /// The lines that stop here, where the proxy knows without asking (not for Muni: see `linesAtStop`).
    let lines: [String]?
    var id: String { code }
}

struct StopLine: Hashable, Decodable, Identifiable {
    let line: String
    let direction: String
    let destination: String
    var stop: String? = nil
    var stopName: String? = nil
    /// Meters from the picked stop; 0 (or missing) for the picked stop itself.
    var distance: Int? = nil
    var lat: Double? = nil
    var lon: Double? = nil
    var id: String { "\(line)|\(direction)|\(stop ?? "")" }

    var isNearby: Bool { (distance ?? 0) > 0 }
}

struct Direction: Hashable, Decodable, Identifiable {
    let id: String
    let name: String
    let destination: String
    let stops: [Stop]
    /// The real street-level route as [[lat, lon]] segments, where the city provides it (Seattle).
    let shapes: [[[Double]]]?
}

struct Stop: Hashable, Decodable, Identifiable {
    let code: String
    let name: String
    let lat: Double?
    let lon: Double?
    var id: String { code }
}

enum TransitError: LocalizedError {
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .badResponse(503): return "Transit data is running late too. Retrying soon."
        case .badResponse(let code): return "Transit data went missing (\(code))"
        }
    }
}

/// When the proxy's 511 snapshot was taken and when a newer one will be ready.
struct Refresh: Equatable {
    let fetchedAt: Date
    let nextRefreshAt: Date

    /// Share of the wait left at `date`: 1 just after a refresh, 0 once newer data is ready.
    func remaining(at date: Date) -> Double {
        let total = nextRefreshAt.timeIntervalSince(fetchedAt)
        guard total > 0 else { return 0 }
        return min(1, max(0, nextRefreshAt.timeIntervalSince(date) / total))
    }
}

/// Client for the bus37-proxy Cloudflare Worker (see /proxy), which caches 511.org data
/// for every stop users have picked so all installs share one API key.
enum TransitService {
    static let baseURL: URL = {
        #if DEBUG
        // Launch with `-proxy http://localhost:8787` to try a proxy running under `wrangler dev`.
        if let local = UserDefaults.standard.string(forKey: "proxy").flatMap(URL.init(string:)) { return local.appending(path: "v1/") }
        #endif
        return URL(string: "https://bus37-proxy.arne-5c1.workers.dev/v1/")!
    }()

    static func departures(for selection: Selection = .current, client: Client) async throws -> [Departure] {
        try await snapshot(for: selection, client: client).departures
    }

    /// Departures plus the proxy's refresh schedule. The proxy fetches every Muni stop from 511
    /// in one shared snapshot, so every stop has the same `fetchedAt` and `nextRefreshAt`.
    static func snapshot(for selection: Selection = .current, client: Client) async throws -> (departures: [Departure], refresh: Refresh) {
        struct Response: Decodable {
            struct Item: Decodable {
                let time: Date
                let live: Bool
                let vehicle: Vehicle?
                let line: String?
            }
            let departures: [Item]
            let fetchedAt: Date
            let nextRefreshAt: Date
        }
        var components = URLComponents(url: url(selection.city, "departures"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            // A stop per line once a line is caught at a nearby stop; one stop for all of them otherwise.
            URLQueryItem(name: "stop", value: selection.also.contains { $0.stopCode != nil }
                ? ([selection.stopCode] + selection.also.map { $0.stopCode ?? selection.stopCode }).joined(separator: ",")
                : selection.stopCode),
            URLQueryItem(name: "line", value: selection.lineIDs.joined(separator: ",")),
            URLQueryItem(name: "direction", value: ([selection.directionID] + selection.also.map(\.directionID)).joined(separator: ",")),
        ]
        let response: Response = try await get(components.url!, client: client)
        let departures = response.departures.map { Departure(time: $0.time, isLive: $0.live, vehicle: $0.vehicle, line: $0.line) }
        saveLastKnown(departures, for: selection)
        return (departures, Refresh(fetchedAt: response.fetchedAt, nextRefreshAt: response.nextRefreshAt))
    }

    // MARK: Last known departures
    //
    // Every successful fetch, by the app or a widget, is kept per stop in the App Group, so a widget
    // whose own fetch fails (it gets little time and network in the background) can still show the
    // times the app just showed instead of a dash.

    private static func lastKnownKey(_ selection: Selection) -> String { "lastKnown-\(selection.id)" }

    private static func saveLastKnown(_ departures: [Departure], for selection: Selection) {
        // Bus positions are only for the map, and stale ones are useless; leave them out.
        let trimmed = departures.prefix(10).map { Departure(time: $0.time, isLive: $0.isLive, line: $0.line) }
        AppGroup.defaults.set(try? JSONEncoder().encode(trimmed), forKey: lastKnownKey(selection))
    }

    /// The departures from the latest successful fetch for `selection`, if any are still ahead.
    static func lastKnownDepartures(for selection: Selection) -> [Departure]? {
        guard let data = AppGroup.defaults.data(forKey: lastKnownKey(selection)),
              let departures = try? JSONDecoder().decode([Departure].self, from: data),
              departures.contains(where: { $0.time > .now })
        else { return nil }
        return departures
    }

    // MARK: Line data, available instantly
    //
    // Lines, their map shapes and stops change only with service changes, a few times a year. So they
    // come from the newest copy on the device (saved from the proxy) or, before the first download,
    // from snapshots bundled with the app (App/Snapshots), and show immediately even offline. The
    // proxy is checked for newer data in the background at most once a day.

    private struct LinesResponse: Decodable { let lines: [Line] }
    private struct MapResponse: Decodable { let lines: [MapLine] }
    private struct DirectionsResponse: Decodable { let directions: [Direction] }
    private struct StopsResponse: Decodable { let stops: [MapStop] }

    /// Every line in `city`, from the device without waiting for the network.
    static func cachedLines(in city: City) -> [Line] {
        (LineData.load("lines-\(city.rawValue)", as: LinesResponse.self))?.lines ?? []
    }

    /// Newer lines from the proxy, or nil when the last check was recent or nothing changed.
    static func refreshedLines(in city: City) async -> [Line]? {
        await LineData.refresh("lines-\(city.rawValue)", from: url(city, "lines"), as: LinesResponse.self)?.lines
    }

    /// Every line in `city` with its route shape and colors, from the device without waiting.
    static func cachedLineMap(in city: City) -> [MapLine] {
        (LineData.load("linemap-\(city.rawValue)", as: MapResponse.self))?.lines ?? []
    }

    /// A newer line map from the proxy, or nil when the last check was recent or nothing changed.
    static func refreshedLineMap(in city: City) async -> [MapLine]? {
        // `v` matches the map format the app understands.
        var components = URLComponents(url: url(city, "map"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "v", value: "2")]
        return await LineData.refresh("linemap-\(city.rawValue)", from: components.url!, as: MapResponse.self)?.lines
    }

    /// Every stop in `city`, from the device without waiting (none before the first download).
    static func cachedStops(in city: City) -> [MapStop] {
        (LineData.load("stops-\(city.rawValue)", as: StopsResponse.self))?.stops ?? []
    }

    /// Newer stops from the proxy, or nil when the last check was recent or nothing changed.
    static func refreshedStops(in city: City) async -> [MapStop]? {
        await LineData.refresh("stops-\(city.rawValue)", from: url(city, "stops"), as: StopsResponse.self)?.stops
    }

    /// A line's directions and stops: from the device if they were loaded before (and are under a
    /// week old), else from the proxy, then kept for next time.
    static func directions(for line: Line, in city: City, client: Client = .app) async throws -> [Direction] {
        let name = "directions-\(city.rawValue)-\(line.id)"
        if let cached = LineData.load(name, as: DirectionsResponse.self, maxAge: 7 * 86_400) {
            return cached.directions
        }
        let data = try await fetch(url(city, "lines").appending(path: line.id), client: client)
        let response = try decoder.decode(DirectionsResponse.self, from: data)
        LineData.save(data, as: name)
        return response.directions
    }

    /// The lines currently serving a stop, each with its direction and destination.
    /// The lines at `stop` and at stops within about 150 m going the same way (`direction`, the
    /// picked direction), nearest first.
    static func nearbyLines(_ stop: String, direction: String, in city: City) async throws -> [StopLine] {
        struct Response: Decodable { let lines: [StopLine] }
        var components = URLComponents(url: url(city, "nearby"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "stop", value: stop), URLQueryItem(name: "direction", value: direction)]
        let response: Response = try await get(components.url!, client: .app)
        return response.lines
    }

    static func linesAtStop(_ stop: String, in city: City) async throws -> [StopLine] {
        struct Response: Decodable { let lines: [StopLine] }
        var components = URLComponents(url: url(city, "stop"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "stop", value: stop)]
        let response: Response = try await get(components.url!, client: .app)
        return response.lines
    }

    /// The lines currently serving any of `stops` (Muni's, up to 40), each with its `stop`.
    static func linesAtStops(_ stops: [String], in city: City) async throws -> [StopLine] {
        struct Response: Decodable { let lines: [StopLine] }
        var components = URLComponents(url: url(city, "stop"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "stop", value: stops.prefix(40).joined(separator: ","))]
        let response: Response = try await get(components.url!, client: .app)
        return response.lines
    }

    /// Like `directions`, but only what's already on the device, for showing stops without waiting.
    static func cachedDirections(for line: Line, in city: City) -> [Direction]? {
        LineData.load("directions-\(city.rawValue)-\(line.id)", as: DirectionsResponse.self)?.directions
    }

    /// The supported city nearest to this device, from the proxy's rough IP-based location.
    /// No location permission is involved; the proxy doesn't store anything.
    static func nearestCity(client: Client = .app) async -> City? {
        struct Response: Decodable { let city: City }
        let response: Response? = try? await get(baseURL.appending(path: "city"), client: client)
        return response?.city
    }

    /// The city the widgets are in, from the same rough IP guess (no location permission), asked at
    /// most every 20 minutes. If the guess fails, the last one stands.
    static func widgetCity() async -> City? {
        let defaults = AppGroup.defaults
        let saved = defaults.string(forKey: "widgetCity").flatMap(City.init(rawValue:))
        if let saved, let at = defaults.object(forKey: "widgetCityAt") as? Date, Date.now.timeIntervalSince(at) < 20 * 60 {
            return saved
        }
        guard let city = await nearestCity(client: .widget) else { return saved }
        defaults.set(city.rawValue, forKey: "widgetCity")
        defaults.set(Date.now, forKey: "widgetCityAt")
        return city
    }

    private static func url(_ city: City, _ path: String) -> URL {
        baseURL.appending(path: city.pathPrefix + path)
    }

    private static func get<T: Decodable>(_ url: URL, client: Client) async throws -> T {
        try decoder.decode(T.self, from: try await fetch(url, client: client))
    }

    fileprivate static func fetch(_ url: URL, client: Client) async throws -> Data {
        #if DEBUG
        // Launch with `-simulateOffline YES` to check what the app shows without a connection.
        if UserDefaults.standard.bool(forKey: "simulateOffline") { throw URLError(.notConnectedToInternet) }
        #endif
        var request = URLRequest(url: url)
        // Anonymous usage statistics; see recordUsage in the proxy.
        request.setValue(AppGroup.installID, forHTTPHeaderField: "X-Install-ID")
        request.setValue(client.rawValue, forHTTPHeaderField: "X-Client")
        request.setValue(String(Selection.favorites.count), forHTTPHeaderField: "X-Favorites")
        request.setValue(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                         forHTTPHeaderField: "X-App-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw TransitError.badResponse(http.statusCode)
        }
        return data
    }

    fileprivate static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        // The proxy sends JavaScript ISO dates, which include milliseconds.
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            return try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string)
        }
        return decoder
    }()
}

/// Line data kept on the device: the newest download in Caches, else the snapshot in the app bundle.
private enum LineData {
    private static var folder: URL {
        let folder = URL.cachesDirectory.appending(path: "LineData", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func file(_ name: String) -> URL { folder.appending(path: "\(name).json") }

    /// The saved copy (if younger than `maxAge`), else the bundled snapshot, decoded.
    static func load<T: Decodable>(_ name: String, as type: T.Type, maxAge: TimeInterval? = nil) -> T? {
        let saved = file(name)
        if let data = try? Data(contentsOf: saved), let value = try? TransitService.decoder.decode(T.self, from: data) {
            let age = (try? saved.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                .map { Date.now.timeIntervalSince($0) } ?? 0
            if maxAge == nil || age < maxAge! { return value }
        }
        guard let bundled = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: bundled) else { return nil }
        return try? TransitService.decoder.decode(T.self, from: data)
    }

    static func save(_ data: Data, as name: String) {
        try? data.write(to: file(name), options: .atomic)
    }

    /// Downloads `url` at most once a day per `name`; returns the new value only if it decodes and
    /// differs from what's on the device, and saves it for next time. Errors (offline) return nil.
    static func refresh<T: Decodable>(_ name: String, from url: URL, as type: T.Type) async -> T? {
        let checkedKey = "lineDataChecked.\(name)"
        if let checked = UserDefaults.standard.object(forKey: checkedKey) as? Date, Date.now.timeIntervalSince(checked) < 86_400 {
            return nil
        }
        guard let data = try? await TransitService.fetch(url, client: .app),
              let value = try? TransitService.decoder.decode(T.self, from: data),
              // The proxy may still be assembling Seattle's map; never replace a full copy with part of one.
              (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["complete"] as? Bool != false
        else { return nil }
        UserDefaults.standard.set(Date.now, forKey: checkedKey)
        let current = (try? Data(contentsOf: file(name)))
            ?? Bundle.main.url(forResource: name, withExtension: "json").flatMap { try? Data(contentsOf: $0) }
        guard strippingTimestamps(current) != strippingTimestamps(data) else { return nil }
        save(data, as: name)
        return value
    }

    /// The proxy stamps each response with when it was built; ignore that when comparing.
    private static func strippingTimestamps(_ data: Data?) -> Data? {
        guard let data, var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
        json["fetchedAt"] = nil
        json["complete"] = nil
        return try? JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
    }
}

import Foundation

/// A city the proxy has live data for.
enum City: String, Codable, CaseIterable, Identifiable {
    case sf, seattle

    var id: String { rawValue }

    var name: String {
        switch self {
        case .sf: "San Francisco"
        case .seattle: "Seattle"
        }
    }

    /// Short tag for tight spaces like widgets, where lines from two cities sit side by side.
    var code: String {
        switch self {
        case .sf: "SF"
        case .seattle: "SEA"
        }
    }

    /// Where this city's endpoints live on the proxy; SF predates the others and has no prefix.
    fileprivate var pathPrefix: String {
        switch self {
        case .sf: ""
        case .seattle: "seattle/"
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

    /// The same line, direction and stop count as one place, whatever the display names say.
    var id: String { "\(city.rawValue)|\(lineID)|\(directionID)|\(stopCode)" }

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
    }
}

struct Departure: Hashable, Codable {
    let time: Date
    let isLive: Bool  // false when there's no bus assigned yet and the time is schedule-based
    var vehicle: Vehicle? = nil
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
        case .badResponse(503): return "Transit data busy, retrying soon"
        case .badResponse(let code): return "Transit data unavailable (\(code))"
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
    static let baseURL = URL(string: "https://bus37-proxy.arne-5c1.workers.dev/v1/")!

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
            }
            let departures: [Item]
            let fetchedAt: Date
            let nextRefreshAt: Date
        }
        var components = URLComponents(url: url(selection.city, "departures"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "stop", value: selection.stopCode),
            URLQueryItem(name: "line", value: selection.lineID),
            URLQueryItem(name: "direction", value: selection.directionID),
        ]
        let response: Response = try await get(components.url!, client: client)
        let departures = response.departures.map { Departure(time: $0.time, isLive: $0.live, vehicle: $0.vehicle) }
        return (departures, Refresh(fetchedAt: response.fetchedAt, nextRefreshAt: response.nextRefreshAt))
    }

    static func lines(in city: City) async throws -> [Line] {
        struct Response: Decodable { let lines: [Line] }
        let response: Response = try await get(url(city, "lines"), client: .app)
        return response.lines
    }

    static func directions(for line: Line, in city: City, client: Client = .app) async throws -> [Direction] {
        struct Response: Decodable { let directions: [Direction] }
        let response: Response = try await get(url(city, "lines").appending(path: line.id), client: client)
        return response.directions
    }

    /// Every line in `city` with its route shape (one cached download from the proxy).
    static func lineMap(in city: City) async throws -> [MapLine] {
        struct Response: Decodable { let lines: [MapLine] }
        // Bump `v` when the map's format changes: iOS caches it for an hour (the proxy's max-age).
        var components = URLComponents(url: url(city, "map"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "v", value: "2")]
        let response: Response = try await get(components.url!, client: .app)
        return response.lines
    }

    /// The supported city nearest to this device, from the proxy's rough IP-based location.
    /// No location permission is involved; the proxy doesn't store anything.
    static func nearestCity() async -> City? {
        struct Response: Decodable { let city: City }
        let response: Response? = try? await get(baseURL.appending(path: "city"), client: .app)
        return response?.city
    }

    private static func url(_ city: City, _ path: String) -> URL {
        baseURL.appending(path: city.pathPrefix + path)
    }

    private static func get<T: Decodable>(_ url: URL, client: Client) async throws -> T {
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
        let decoder = JSONDecoder()
        // The proxy sends JavaScript ISO dates, which include milliseconds.
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            return try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string)
        }
        return try decoder.decode(T.self, from: data)
    }
}

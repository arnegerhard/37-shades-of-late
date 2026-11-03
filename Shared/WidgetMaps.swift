import AppIntents
import MapKit
import SwiftUI
import WidgetKit

// The map widget ("Favorites map"): a favorite's route as a picture the app drew ahead of time (see
// WidgetMapPainter), with the buses and times laid over it as the widget fetches them. Drawing a map in
// the widget itself would take more memory than iOS gives a widget; showing a picture takes a little.

/// The pictures' shapes, one per layout, in points: the small widget's whole face, the medium's left
/// third, the large's top half.
enum WidgetMapShape: String, CaseIterable, Codable {
    case square, tall, wide

    var size: CGSize {
        switch self {
        case .square: CGSize(width: 170, height: 170)
        case .tall: CGSize(width: 128, height: 142)
        case .wide: CGSize(width: 340, height: 204)
        }
    }

    /// The part of the picture the route is kept in, as fractions: clear of what's laid over it.
    var routeArea: CGRect {
        switch self {
        // Over the small widget's bottom: the line, the stop and the countdown.
        case .square: CGRect(x: 0.08, y: 0.06, width: 0.84, height: 0.56)
        // Over the large widget's bottom left: the stop's name.
        case .wide: CGRect(x: 0.06, y: 0.07, width: 0.88, height: 0.76)
        default: CGRect(x: 0.07, y: 0.08, width: 0.86, height: 0.84)
        }
    }
}

/// Where a picture's map is (so the buses can be put on it) and where its stop is.
struct WidgetMapInfo: Codable {
    /// The map rect the picture shows: x, y, width, height in map points.
    let rect: [Double]
    let stop: [Double]?
    let version: Int

    static let currentVersion = 2

    var mapRect: MKMapRect { MKMapRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]) }

    /// Where `coordinate` is on the picture, as fractions of its size.
    func fraction(of coordinate: CLLocationCoordinate2D) -> CGPoint {
        let point = MKMapPoint(coordinate)
        return CGPoint(x: (point.x - rect[0]) / rect[2], y: (point.y - rect[1]) / rect[3])
    }
}

enum WidgetMaps {
    /// In the App Group's container, where the app writes and the widget reads.
    static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.info.jetsons.bus37")?
            .appending(path: "WidgetMaps", directoryHint: .isDirectory)
    }

    /// A favorite's name on disk: its id, hashed (FNV-1a), as ids hold characters file names can't.
    static func key(_ selection: Selection) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in selection.id.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 36)
    }

    static func imageURL(_ selection: Selection, _ shape: WidgetMapShape, dark: Bool) -> URL? {
        folder?.appending(path: "\(key(selection))-\(shape.rawValue)\(dark ? "-dark" : "").jpg")
    }

    static func infoURL(_ selection: Selection, _ shape: WidgetMapShape) -> URL? {
        folder?.appending(path: "\(key(selection))-\(shape.rawValue).json")
    }

    static func info(_ selection: Selection, _ shape: WidgetMapShape) -> WidgetMapInfo? {
        guard let url = infoURL(selection, shape), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetMapInfo.self, from: data)
    }

    /// The favorite the medium and large widgets have on their map, as its row was last tapped.
    static let shownKey = "widgetMapShown"
}

// MARK: - The setting and the switch

/// A favorite, for the map widget's setting.
struct FavoriteEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Favorite"
    static var defaultQuery = FavoritesQuery()

    let id: String
    let title: String

    init(_ selection: Selection) {
        id = selection.id
        title = "\(selection.lineLabel) at \(selection.stopName)"
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct FavoritesQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [FavoriteEntity] {
        Selection.favorites.filter { identifiers.contains($0.id) }.map(FavoriteEntity.init)
    }

    func suggestedEntities() async throws -> [FavoriteEntity] {
        Selection.favorites.map(FavoriteEntity.init)
    }
}

/// The map widget's setting (long-press, Edit Widget): which favorite it shows; none, the first where
/// you are. Several small ones, each set to another, stack into a Smart Stack to swipe through.
struct MapWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Favorites map"
    static var description = IntentDescription("Which favorite the map shows first.")

    @Parameter(title: "Favorite") var favorite: FavoriteEntity?

    init() {}
}

/// A row tapped in the medium or large map widget: its favorite goes on the map.
struct ShowOnMapIntent: AppIntent {
    static var title: LocalizedStringResource = "Show on the map"
    static var isDiscoverable = false

    @Parameter(title: "Favorite") var id: String

    init() {}
    init(_ selection: Selection) { id = selection.id }

    func perform() async throws -> some IntentResult {
        AppGroup.defaults.set(id, forKey: WidgetMaps.shownKey)
        return .result()
    }
}

// MARK: - The views

/// A favorite's map picture, with its stop and the buses on their way where they were last seen.
struct WidgetMapImage: View {
    let row: WidgetRow
    let shape: WidgetMapShape
    let date: Date
    /// The minutes next to the buses: every one's, the next one's only (where there's little room), or none.
    var labels = Labels.all

    enum Labels { case all, next, none }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            let frame = geometry.size
            if let url = WidgetMaps.imageURL(row.selection, shape, dark: colorScheme == .dark),
               let image = UIImage(contentsOfFile: url.path(percentEncoded: false)),
               let info = WidgetMaps.info(row.selection, shape) {
                // Filling the frame as the picture does (`scaledToFill`), so the buses land on it.
                let scale = max(frame.width / shape.size.width, frame.height / shape.size.height)
                let drawn = CGSize(width: shape.size.width * scale, height: shape.size.height * scale)
                let offset = CGPoint(x: (frame.width - drawn.width) / 2, y: (frame.height - drawn.height) / 2)
                let place = { (coordinate: CLLocationCoordinate2D) -> CGPoint in
                    let f = info.fraction(of: coordinate)
                    return CGPoint(x: offset.x + f.x * drawn.width, y: offset.y + f.y * drawn.height)
                }
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: frame.width, height: frame.height)
                    ForEach(Array(buses.enumerated()), id: \.element.time) { index, departure in
                        if let vehicle = departure.vehicle {
                            let spot = place(CLLocationCoordinate2D(latitude: vehicle.lat, longitude: vehicle.lon))
                            if spot.x > 4, spot.y > 4, spot.x < frame.width - 4, spot.y < frame.height - 4 {
                                bus(departure, labeled: labels == .all || labels == .next && index == 0).position(spot)
                            }
                        }
                    }
                }
                .frame(width: frame.width, height: frame.height)
                .clipped()
            } else {
                // Not drawn yet: the app draws it the next time it's opened.
                ZStack {
                    Color(.secondarySystemBackground)
                    Image(systemName: "map").font(.title3).foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// The next few live buses.
    private var buses: [Departure] {
        Array(row.departures.filter { $0.time > date.addingTimeInterval(-30) && $0.vehicle != nil }.prefix(3))
    }

    private func bus(_ departure: Departure, labeled: Bool) -> some View {
        let minutes = max(0, Int(departure.time.timeIntervalSince(date) / 60))
        let color = Color(hex: LineBadge.color(of: departure.line ?? row.selection.lineID, in: row.selection.city)?.hex) ?? LineBadge.red
        return HStack(spacing: 2) {
            Circle()
                .fill(Color(white: 0.1))
                .overlay(Circle().strokeBorder(color, lineWidth: 2))
                .overlay(Circle().strokeBorder(.white, lineWidth: 0.75).padding(-0.75))
                .frame(width: 11, height: 11)
            if labeled {
                Text(minutes == 0 ? "now" : "\(minutes)")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .background(Color(white: 0.1).opacity(0.85), in: Capsule())
            }
        }
        .fixedSize()
    }
}

/// The map widget, in its three sizes: small, the map with the line and countdown over it; medium, the
/// map beside every favorite's times; large, the map over them. In medium and large a row's tap puts its
/// favorite on the map; the map's opens it in the app.
struct MapWidgetView: View {
    let entry: DeparturesEntry
    let family: WidgetFamily
    /// Drawn in the app (the screenshots' showcase), where there's no widget container to paint the background.
    var inApp = false

    private let maxRows = 4

    /// The favorite on the map: the one set for this widget in the small one; in the others the one last
    /// tapped, if it's here, else the one set, else the first.
    private var shown: WidgetRow? {
        let rows = entry.rows
        if family != .systemSmall, let tapped = AppGroup.defaults.string(forKey: WidgetMaps.shownKey),
           let row = rows.prefix(maxRows).first(where: { $0.selection.id == tapped }) { return row }
        return rows.first { $0.selection.id == entry.pinned } ?? rows.first
    }

    var body: some View {
        Group {
            if let shown {
                switch family {
                case .systemSmall: small(shown)
                case .systemLarge: large(shown)
                default: medium(shown)
                }
            } else {
                Text(entry.error ?? "No favorites yet").font(.caption).foregroundStyle(.secondary)
                    .padding(12)
                    ._widgetBackground(inApp) { Color(.systemBackground) }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    // MARK: Small

    private func small(_ row: WidgetRow) -> some View {
        let next = entry.upcoming(row).first
        return VStack(alignment: .leading, spacing: 2) {
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                LineBadges(parts: row.selection.badgeParts, font: .system(.footnote, design: .rounded).weight(.heavy), round: row.selection.roundBadge)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 0)
                Group {
                    if let next {
                        let minutes = entry.minutes(until: next)
                        Text(minutes == 0 ? "now" : "\(minutes)") + Text(minutes == 0 ? "" : " min").font(.system(.caption, design: .rounded).weight(.bold))
                    } else {
                        Text(row.failed ? "–" : "none")
                    }
                }
                .font(.system(.title2, design: .rounded).weight(.heavy))
                .monospacedDigit()
                .foregroundStyle(next?.isLive == true ? .green : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            }
            Text(row.selection.stopName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        }
        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
        .padding(12)
        .widgetURL(row.selection.openURL.tapped(on: "home"))
        ._widgetBackground(inApp) {
            WidgetMapImage(row: row, shape: .square, date: entry.date, labels: .none)
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 70)
                }
        }
    }

    // MARK: Medium

    private func medium(_ shown: WidgetRow) -> some View {
        HStack(spacing: 10) {
            Link(destination: shown.selection.openURL.tapped(on: "home")) {
                WidgetMapImage(row: shown, shape: .tall, date: entry.date, labels: .next)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .frame(width: WidgetMapShape.tall.size.width)
            VStack(spacing: 2) {
                ForEach(entry.rows.prefix(maxRows), id: \.self) { row in
                    switchRow(row, shown: row == shown, destination: false)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        ._widgetBackground(inApp) { Color(.systemBackground) }
    }

    // MARK: Large

    private func large(_ shown: WidgetRow) -> some View {
        VStack(spacing: 8) {
            Link(destination: shown.selection.openURL.tapped(on: "home")) {
                WidgetMapImage(row: shown, shape: .wide, date: entry.date)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        Text(shown.selection.stopName)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.regularMaterial, in: Capsule())
                            .padding(6)
                    }
            }
            .frame(height: WidgetMapShape.wide.size.height)
            VStack(spacing: 3) {
                ForEach(entry.rows.prefix(maxRows), id: \.self) { row in
                    switchRow(row, shown: row == shown, destination: true)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        ._widgetBackground(inApp) { Color(.systemBackground) }
    }

    /// A favorite's row: its line (with where it goes, if there's room) and its next times; tapped, it
    /// goes on the map.
    private func switchRow(_ row: WidgetRow, shown: Bool, destination: Bool) -> some View {
        let next = entry.upcoming(row).first
        return Button(intent: ShowOnMapIntent(row.selection)) {
            HStack(spacing: 6) {
                if let tag = entry.cityTag(for: row, visible: maxRows) { CityTag(code: tag) }
                LineBadges(parts: row.selection.badgeParts, font: .system(.subheadline, design: .rounded).weight(.heavy),
                           round: row.selection.roundBadge)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(2)
                if destination {
                    Text(row.selection.destination).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 2)
                Group {
                    if entry.upcoming(row).isEmpty {
                        Text(row.failed ? "–" : "none")
                    } else {
                        WaitsLabel(departures: entry.upcoming(row), date: entry.date,
                                   count: (destination ? 3 : 2) - (row.selection.isMultiLine ? 1 : 0), selection: row.selection,
                                   badgeFont: .system(size: 10, weight: .heavy, design: .rounded))
                    }
                }
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .layoutPriority(1)
                .foregroundStyle(next?.isLive == true ? .green : .secondary)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: destination ? 34 : 30)
            .background(shown ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    /// The widget's background: in its container in a widget, behind it in the app.
    @ViewBuilder func _widgetBackground(_ inApp: Bool, @ViewBuilder _ background: () -> some View) -> some View {
        if inApp { self.background { background() } } else { containerBackground(for: .widget) { background() } }
    }
}

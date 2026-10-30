import MapKit
import SwiftUI

/// Which cities to show in the app, picked on a map of the US: a card per city with its trains drawn
/// in their colors, tied to where the city is. Tapping a card picks it or leaves it out; picked ones
/// are lit up, the rest dimmed. (The agencies' logos would say it faster, but they're licensed only:
/// the lines' own colors say it too.)
struct CityMap: View {
    @Binding var chosen: Set<City>
    /// Where the map has each city, once it's drawn (at this zoom it's a globe, so it says).
    @State private var spots: [City: CGPoint] = [:]

    /// The lower 48, between the cards above and below it.
    private static let us = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 37.5, longitude: -96),
                                               span: MKCoordinateSpan(latitudeDelta: 24, longitudeDelta: 62))

    /// Where each city's card goes: above the map (the north) or below it, left to right, so the
    /// lines to them don't cross. New York, Boston and Washington are too close to fit next to each
    /// other, and so are San Francisco and Los Angeles.
    private static let slots: [City: (top: Bool, column: Int)] = [
        .seattle: (true, 0), .chicago: (true, 1), .boston: (true, 2),
        .sf: (false, 0), .la: (false, 1), .dc: (false, 2), .nyc: (false, 3),
    ]

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            // As wide as the fullest row lets them be; each row spread across.
            let columns = { (top: Bool) in CGFloat(Self.slots.values.filter { $0.top == top }.count) }
            let cardWidth = min(124, (size.width - 10 - (max(columns(true), columns(false)) * 10)) / max(columns(true), columns(false)))
            let cardHeight = cardWidth * 1.05
            // The name and who runs it take a quarter of the card, under its map; the subtitles all at
            // one size, which fits the longest ("Metro · Sound Transit") across.
            let textHeight = (cardHeight - 2 * CityCard.inset) / 4
            let widest = City.allCases.map { ($0.agencies as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 10)]).width }.max() ?? 1
            let subtitleSize = min(textHeight * 0.4, 10 * (cardWidth - 2 * CityCard.inset) / widest * 0.9)
            let card = { (city: City) -> CGPoint in
                let slot = Self.slots[city] ?? (true, 1)
                let x = (size.width - 2 * 10) / columns(slot.top) * (CGFloat(slot.column) + 0.5) + 10
                return CGPoint(x: x, y: slot.top ? cardHeight / 2 + 10 : size.height - cardHeight / 2 - 10)
            }
            MapReader { proxy in
                ZStack {
                    Map(initialPosition: .region(Self.us), interactionModes: [])
                        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
                        .onMapCameraChange(frequency: .onEnd) { spots = Self.spots(proxy) }
                        // And once it's in place: sliding in (after the widget walkthrough), it says where
                        // the cities are from where it is on the way, and nothing tells it it's arrived.
                        .task {
                            try? await Task.sleep(for: .seconds(0.6))
                            spots = Self.spots(proxy)
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)

                    // From each city to its card.
                    Canvas { context, _ in
                        for city in City.allCases {
                            guard let at = spots[city] else { continue }
                            let to = card(city)
                            let edge = CGPoint(x: to.x, y: to.y + (to.y < at.y ? 1 : -1) * cardHeight / 2)
                            var line = Path()
                            line.move(to: at)
                            line.addLine(to: edge)
                            let picked = chosen.contains(city)
                            context.stroke(line, with: .color(.white.opacity(picked ? 0.7 : 0.3)), lineWidth: 1)
                            context.fill(Path(ellipseIn: CGRect(x: at.x - 4, y: at.y - 4, width: 8, height: 8)),
                                         with: .color(picked ? LineBadge.red : Color(white: 0.6)))
                        }
                    }
                    .allowsHitTesting(false)

                    ForEach(City.allCases) { city in
                        // Too narrow for "Washington, D.C.": by their codes, as the crowded city tabs.
                        CityCard(city: city, isChosen: chosen.contains(city), byCode: cardWidth < 100,
                                 textHeight: textHeight, subtitleSize: subtitleSize) {
                            withAnimation(.snappy) {
                                if chosen.contains(city) { chosen.remove(city) } else { chosen.insert(city) }
                            }
                        }
                        .frame(width: cardWidth, height: cardHeight)
                        .position(card(city))
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private static func spots(_ proxy: MapProxy) -> [City: CGPoint] {
        Dictionary(uniqueKeysWithValues: City.allCases.compactMap { city in
            proxy.convert(CLLocationCoordinate2D(latitude: city.center.lat, longitude: city.center.lon), to: .local)
                .map { (city, $0) }
        })
    }
}

/// A city on the map: its trains, its name and whose they are.
private struct CityCard: View {
    let city: City
    let isChosen: Bool
    /// "DC" rather than "Washington, D.C.".
    var byCode = false
    /// How much of the card the name and subtitle take, and the subtitle's size, the same on every card.
    let textHeight: CGFloat
    let subtitleSize: CGFloat
    static let inset: CGFloat = 5
    let toggle: () -> Void
    @State private var lines: [MapLine] = []

    var body: some View {
        Button(action: toggle) {
            VStack(spacing: 0) {
                NetworkMap(lines: lines)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .saturation(isChosen ? 1 : 0)
                    .opacity(isChosen ? 1 : 0.5)
                VStack(spacing: 0) {
                    Text(byCode ? city.code : city.name)
                        .font(.system(size: textHeight * 0.5, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(city.agencies)
                        .font(.system(size: subtitleSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(height: textHeight)
            }
            .padding(Self.inset)
            .foregroundStyle(isChosen ? .primary : .secondary)
            .background(RoundedRectangle(cornerRadius: 14).fill(isChosen ? Color(white: 0.17) : Color(white: 0.09).opacity(0.9)))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isChosen ? LineBadge.red : .white.opacity(0.12), lineWidth: isChosen ? 2 : 1)
            }
            .overlay(alignment: .topTrailing) {
                if isChosen {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.white, LineBadge.red)
                        .offset(x: 6, y: -6)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(city.name), \(city.agencies)")
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .task {
            // The big cities' maps take a moment to read; off the main thread.
            let city = city
            lines = await Task.detached { TransitService.cachedLineMap(in: city).filter { $0.isNetwork(in: city) } }.value
        }
    }
}

/// A city's trains on its map, in the app's map style: a still picture of the map with the lines drawn
/// on it where they run. (A live map this small wouldn't zoom out far enough, and each would carry
/// its own Legal link; the map of the US behind the cards has it.)
private struct NetworkMap: View {
    let lines: [MapLine]
    @State private var picture: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(white: 0.12)
                if let picture { Image(uiImage: picture).resizable() }
            }
            .task(id: "\(geo.size.width)x\(geo.size.height) \(lines.count)") {
                picture = await Self.picture(of: lines, size: geo.size)
            }
        }
        .accessibilityHidden(true)
    }

    private static func picture(of lines: [MapLine], size: CGSize) async -> UIImage? {
        let points = lines.flatMap { $0.shapes.joined() }
        guard size.width > 0, size.height > 0,
              let minLat = points.map({ $0[0] }).min(), let maxLat = points.map({ $0[0] }).max(),
              let minLon = points.map({ $0[1] }).min(), let maxLon = points.map({ $0[1] }).max() else { return nil }
        let options = MKMapSnapshotter.Options()
        // Around every line, with a little room; the picture widens it to its own shape.
        options.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
                                            span: MKCoordinateSpan(latitudeDelta: (maxLat - minLat) * 1.15, longitudeDelta: (maxLon - minLon) * 1.15))
        // Bigger, then shrunk into the card: the map's labels come out smaller, enough to show where it
        // is without covering the lines. Not twice: from about there MapKit stamps each picture with
        // its logo, which the map of the US behind the cards carries already.
        let zoom: CGFloat = 1.75
        options.size = CGSize(width: size.width * zoom, height: size.height * zoom)
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        options.preferredConfiguration = configuration
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }
        return UIGraphicsImageRenderer(size: size).image { renderer in
            snapshot.image.draw(in: CGRect(origin: .zero, size: size))
            let context = renderer.cgContext
            context.setLineWidth(1.5)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            for line in lines {
                context.setStrokeColor(UIColor((Color(hex: line.color) ?? LineBadge.red).legible(on: .dark)).cgColor)
                for shape in line.shapes where shape.count > 1 {
                    let at = shape.map { p -> CGPoint in
                        let at = snapshot.point(for: CLLocationCoordinate2D(latitude: p[0], longitude: p[1]))
                        return CGPoint(x: at.x / zoom, y: at.y / zoom)
                    }
                    context.addLines(between: at)
                }
                context.strokePath()
            }
        }
    }
}

private extension MapLine {
    /// Whether it's one of the trains a city is known by: subways, light rail, streetcars and cable
    /// cars, BART, PATH and the Staten Island Railway; not buses, ferries, water taxis, or commuter
    /// trains, which run a state away and would leave the city a dot.
    func isNetwork(in city: City) -> Bool {
        switch mode {
        case "subway", "cableway": true
        case "metro": !name.hasPrefix("Water Taxi")
        case "rail": city == .sf || city == .nyc
        default: false
        }
    }
}

extension City {
    /// Who runs what the app shows there, as riders call them.
    var agencies: String {
        switch self {
        case .sf: "Muni · BART · ferries"
        case .seattle: "Metro · Sound Transit"
        case .nyc: "MTA · PATH · ferries"
        case .boston: "MBTA"
        case .chicago: "CTA"
        case .dc: "Metro · Metrobus"
        case .la: "LA Metro"
        }
    }
}

/// The cities to show in the app, on the map of them: after the widget walkthrough, and from the
/// city picker's edit button. At least one stays picked.
struct CityChooser: View {
    /// On the welcome screen: the nearest city starts out picked, and Done goes on to the app.
    var isWelcome = false
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chosen = Set(City.picked ?? [])

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !isWelcome {
                HStack {
                    Button("Cancel") { dismiss() }
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
            }
            Text("Where do you ride?")
                .font(.largeTitle.bold())
                .padding(.horizontal, 24)
                .padding(.top, isWelcome ? 28 : 12)
            Text(isWelcome ? "Tap the cities you wait in. Only those show up in the app. Change them anytime with the pencil next to the cities."
                           : "Tap the cities you wait in. Only those show up in the app.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.top, 6)
            CityMap(chosen: $chosen)
                .padding(.horizontal, 12)
                .padding(.vertical, 16)
            Button {
                City.chosen = Array(chosen)
                onDone()
            } label: {
                Text(chosen.isEmpty ? "Pick at least one" : isWelcome ? "Start suffering" : "Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(LineBadge.red)
            .disabled(chosen.isEmpty)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .background(Color(.systemBackground))
        .preferredColorScheme(.dark)
        .task {
            // To start with, the cities with favorites (after an update), or where this phone seems to be.
            guard isWelcome, chosen.isEmpty else { return }
            let withFavorites = Set(Selection.favorites.map(\.city))
            if !withFavorites.isEmpty { return chosen = withFavorites }
            if let nearest = await TransitService.nearestCity(), chosen.isEmpty {
                withAnimation(.snappy) { _ = chosen.insert(nearest) }
            }
        }
    }
}

/// Before the home screen, the first time: how to add the Lock Screen widget, then which cities to
/// show. After an update from before there were cities to pick, just the cities.
struct Welcome: View {
    let onDone: () -> Void
    @State private var pickingCities = WidgetGuide.hasBeenShown

    static var isNeeded: Bool {
        #if DEBUG
        // Screenshot runs open a specific screen; don't cover it.
        if UserDefaults.standard.string(forKey: "screen") != nil { return false }
        #endif
        return !WidgetGuide.hasBeenShown || City.picked == nil
    }

    var body: some View {
        if pickingCities {
            CityChooser(isWelcome: true, onDone: onDone)
                .transition(.move(edge: .trailing))
        } else {
            WidgetGuide {
                // Skipped or done, the cities come next, unless they're picked already.
                if City.picked == nil { withAnimation(.snappy) { pickingCities = true } } else { onDone() }
            }
        }
    }
}

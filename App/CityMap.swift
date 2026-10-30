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
    /// lines to them don't cross. New York, Boston and Washington are too close to fit next to each other.
    private static let slots: [City: (top: Bool, column: Int)] = [
        .seattle: (true, 0), .chicago: (true, 1), .boston: (true, 2),
        .sf: (false, 0), .dc: (false, 1), .nyc: (false, 2),
    ]

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let cardWidth = min(124, (size.width - 4 * 10) / 3)
            let cardHeight = cardWidth * 0.85
            let card = { (city: City) -> CGPoint in
                let slot = Self.slots[city] ?? (true, 1)
                let x = (size.width - 2 * 10) / 3 * (CGFloat(slot.column) + 0.5) + 10
                return CGPoint(x: x, y: slot.top ? cardHeight / 2 + 10 : size.height - cardHeight / 2 - 10)
            }
            MapReader { proxy in
                ZStack {
                    Map(initialPosition: .region(Self.us), interactionModes: [])
                        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
                        .onMapCameraChange(frequency: .onEnd) {
                            spots = Dictionary(uniqueKeysWithValues: City.allCases.compactMap { city in
                                proxy.convert(CLLocationCoordinate2D(latitude: city.center.lat, longitude: city.center.lon), to: .local)
                                    .map { (city, $0) }
                            })
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
                        CityCard(city: city, isChosen: chosen.contains(city)) {
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
}

/// A city on the map: its trains, its name and whose they are.
private struct CityCard: View {
    let city: City
    let isChosen: Bool
    let toggle: () -> Void
    @State private var lines: [MapLine] = []

    var body: some View {
        Button(action: toggle) {
            VStack(spacing: 3) {
                NetworkDrawing(lines: lines)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .saturation(isChosen ? 1 : 0)
                    .opacity(isChosen ? 1 : 0.5)
                Text(city.name)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(city.agencies)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(8)
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

/// Lines drawn to fit, in their colors (on a flat projection, fine at city scale).
private struct NetworkDrawing: View {
    let lines: [MapLine]

    var body: some View {
        Canvas { context, size in
            let points = lines.flatMap { $0.shapes.joined() }
            guard let minLat = points.map({ $0[0] }).min(), let maxLat = points.map({ $0[0] }).max(),
                  let minLon = points.map({ $0[1] }).min(), let maxLon = points.map({ $0[1] }).max() else { return }
            let squeeze = cos((minLat + maxLat) / 2 * .pi / 180)
            let scale = min(size.width / max((maxLon - minLon) * squeeze, 1e-6), size.height / max(maxLat - minLat, 1e-6))
            let place = { (p: [Double]) in
                CGPoint(x: size.width / 2 + (p[1] - (minLon + maxLon) / 2) * squeeze * scale,
                        y: size.height / 2 - (p[0] - (minLat + maxLat) / 2) * scale)
            }
            for line in lines {
                var path = Path()
                for shape in line.shapes where shape.count > 1 {
                    path.move(to: place(shape[0]))
                    for p in shape.dropFirst() { path.addLine(to: place(p)) }
                }
                let color = (Color(hex: line.color) ?? LineBadge.red).legible(on: .dark)
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
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
            // Where this phone seems to be, to start with.
            if isWelcome, chosen.isEmpty, let nearest = await TransitService.nearestCity(), chosen.isEmpty {
                withAnimation(.snappy) { _ = chosen.insert(nearest) }
            }
        }
    }
}

/// The first launch: how to add the Lock Screen widget, then which cities to show.
struct Welcome: View {
    let onDone: () -> Void
    @State private var pickingCities = false

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

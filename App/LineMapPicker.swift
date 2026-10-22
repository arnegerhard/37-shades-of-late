import MapKit
import SwiftUI

/// Every line in a city drawn on one map. Tap near a line to select it; when several lines run
/// close together the nearby ones are offered as chips. "Choose stop" continues to the stop picker.
struct LineMapPicker: View {
    let city: City

    @State private var lines: [MapLine] = []
    @State private var paths: [String: [[CLLocationCoordinate2D]]] = [:]
    @State private var candidates: [MapLine] = []
    @State private var selectedID: String?
    @State private var error: String?
    @State private var position: MapCameraPosition
    @Environment(\.colorScheme) private var colorScheme

    init(city: City) {
        self.city = city
        _position = State(initialValue: .region(city.region))
    }

    private var selected: MapLine? { candidates.first { $0.id == selectedID } }

    private var drawOrder: [MapLine] {
        lines.filter { $0.id != selectedID } + lines.filter { $0.id == selectedID }
    }

    var body: some View {
        MapReader { proxy in
            Map(position: $position) {
                // Selected line last, so it's drawn on top of the lines it shares streets with.
                ForEach(drawOrder) { line in
                    let isSelected = line.id == selectedID
                    let isCandidate = !isSelected && candidates.contains { $0.id == line.id }
                    // Many lines share a color (all Muni buses are blue), so only the selected line
                    // keeps full strength; nearby ones stay a bit clearer than the rest.
                    ForEach(Array((paths[line.id] ?? []).enumerated()), id: \.offset) { _, path in
                        MapPolyline(coordinates: path)
                            .stroke(line.mapColor.legible(on: colorScheme)
                                        .opacity(selectedID == nil || isSelected ? 1 : isCandidate ? 0.5 : 0.22),
                                    style: StrokeStyle(lineWidth: isSelected ? 7 : isCandidate ? 3.5 : 3,
                                                       lineCap: .round, lineJoin: .round))
                    }
                }
            }
            // A muted base map lets the route colors carry the picture.
            .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
            // Alongside the map's own gestures, which would otherwise swallow a plain tap.
            .simultaneousGesture(SpatialTapGesture().onEnded { tap in select(near: tap.location, proxy: proxy) })
        }
        .safeAreaInset(edge: .bottom) { card }
        .overlay {
            if let error {
                ContentUnavailableView("Couldn't load the map", systemImage: "map", description: Text(error))
                    .background(.regularMaterial)
            } else if lines.isEmpty {
                ProgressView()
            }
        }
        .task(id: city) {
            lines = []
            paths = [:]
            candidates = []
            selectedID = nil
            error = nil
            position = .region(city.region)
            do {
                let loaded = try await TransitService.lineMap(in: city)
                paths = Dictionary(uniqueKeysWithValues: loaded.map { line in
                    (line.id, line.shapes.map { $0.compactMap { $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil } })
                })
                lines = loaded
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @ViewBuilder private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selected {
                if candidates.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(candidates) { line in
                                Button { selectedID = line.id } label: {
                                    LineBadge(line: line.id, font: .system(.subheadline, design: .rounded).weight(.heavy),
                                              color: line.mapColor, textColor: line.badgeTextColor)
                                        .opacity(line.id == selectedID ? 1 : 0.55)
                                        .padding(3)
                                        .overlay {
                                            if line.id == selectedID {
                                                RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.6), lineWidth: 1.5)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Line \(line.id), \(line.name)")
                            }
                        }
                    }
                }
                HStack(spacing: 12) {
                    LineBadge(line: selected.id, font: .system(.title3, design: .rounded).weight(.heavy),
                              color: selected.mapColor, textColor: selected.badgeTextColor)
                    Text(selected.name).font(.headline).lineLimit(2)
                    Spacer(minLength: 0)
                    NavigationLink(value: selected.line) {
                        Text("Choose stop").font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LineBadge.red)
                }
            } else {
                Label(lines.isEmpty ? "Loading lines…" : "Tap a line on the map to pick it.", systemImage: "hand.tap")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding()
    }

    /// Lines within about a fingertip (24 pt) of the tap, nearest first.
    private func select(near point: CGPoint, proxy: MapProxy) {
        guard let tap = proxy.convert(point, from: .local),
              let edge = proxy.convert(CGPoint(x: point.x + 24, y: point.y), from: .local)
        else { return }
        let reach = meters(tap, edge)
        let nearby = lines
            .compactMap { line -> (MapLine, Double)? in
                let distance = (paths[line.id] ?? []).map { distanceToPath(tap, $0) }.min() ?? .infinity
                return distance <= reach ? (line, distance) : nil
            }
            .sorted { $0.1 < $1.1 }
            .prefix(8)
            .map(\.0)
        withAnimation(.snappy(duration: 0.25)) {
            candidates = Array(nearby)
            selectedID = nearby.first?.id
        }
    }
}

extension MapLine {
    /// The agency's official color, or Muni red where it doesn't publish one.
    var mapColor: Color { Color(hex: color) ?? LineBadge.red }
    var badgeTextColor: Color { Color(hex: textColor) ?? .white }
}

extension Color {
    /// The same hue, brightened on dark maps (Muni's navy blue nearly vanishes there) and darkened
    /// on light maps when it's too pale, so every line stands out from the streets.
    func legible(on scheme: ColorScheme) -> Color {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(self).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else { return self }
        // Greys (Muni's owl and bus-substitute routes) stay a quiet mid grey in both modes.
        if saturation < 0.15 { return Color(white: scheme == .dark ? 0.62 : 0.5, opacity: alpha) }
        if scheme == .dark {
            // Lift dark colors and soften their saturation a little so they glow instead of looking muddy.
            return Color(hue: hue, saturation: brightness < 0.8 ? min(saturation, 0.85) : saturation,
                         brightness: max(brightness, 0.92), opacity: alpha)
        }
        return Color(hue: hue, saturation: max(saturation, 0.55), brightness: min(brightness, 0.78), opacity: alpha)
    }
}

extension City {
    /// The area the line map opens on.
    var region: MKCoordinateRegion {
        switch self {
        case .sf:
            MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 37.765, longitude: -122.44),
                               span: MKCoordinateSpan(latitudeDelta: 0.13, longitudeDelta: 0.13))
        case .seattle:
            MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 47.62, longitude: -122.32),
                               span: MKCoordinateSpan(latitudeDelta: 0.22, longitudeDelta: 0.22))
        }
    }
}

// MARK: - Distances in meters (flat-earth, fine at city scale)

private func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
    let x = (b.longitude - a.longitude) * 111_320 * cos(a.latitude * .pi / 180)
    let y = (b.latitude - a.latitude) * 110_540
    return (x * x + y * y).squareRoot()
}

private func distanceToPath(_ point: CLLocationCoordinate2D, _ path: [CLLocationCoordinate2D]) -> Double {
    let lonScale = 111_320 * cos(point.latitude * .pi / 180)
    func local(_ c: CLLocationCoordinate2D) -> (x: Double, y: Double) {
        ((c.longitude - point.longitude) * lonScale, (c.latitude - point.latitude) * 110_540)
    }
    var best = Double.infinity
    for (a, b) in zip(path, path.dropFirst()) {
        let (p, q) = (local(a), local(b))
        let (dx, dy) = (q.x - p.x, q.y - p.y)
        let length = dx * dx + dy * dy
        let t = length > 0 ? max(0, min(1, -(p.x * dx + p.y * dy) / length)) : 0
        let (x, y) = (p.x + t * dx, p.y + t * dy)
        best = min(best, (x * x + y * y).squareRoot())
    }
    return best
}

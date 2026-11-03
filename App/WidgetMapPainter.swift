import MapKit
import SwiftUI
import WidgetKit

/// Draws each favorite's map for the map widget (see WidgetMaps.swift), in each of its shapes, light and
/// dark: the route in its lines' colors and the stop, framed to fit, on a muted map. Widgets haven't the
/// memory to draw maps; the app has, so it draws them ahead of time, whenever there's one missing.
@MainActor
enum WidgetMapPainter {
    private static var painting: Task<Void, Never>?

    /// Draws what's missing for `favorites`, and drops what's there for stops no longer among them.
    static func paint(_ favorites: [Selection]) {
        guard painting == nil, let folder = WidgetMaps.folder else { return }
        painting = Task {
            defer { painting = nil }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var drew = false
            for selection in favorites where !Task.isCancelled {
                let missing = WidgetMapShape.allCases.filter { shape in
                    WidgetMaps.info(selection, shape)?.version != WidgetMapInfo.currentVersion
                        || [false, true].contains { dark in
                            WidgetMaps.imageURL(selection, shape, dark: dark).map { !FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? true
                        }
                }
                guard !missing.isEmpty, let loaded = await LiveRoute.load(selection) else { continue }
                for shape in missing {
                    if await paint(selection, loaded: loaded, shape: shape) { drew = true }
                }
            }
            // Pictures of stops that aren't favorites any more.
            let kept = Set(favorites.map(WidgetMaps.key))
            for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                if let key = file.lastPathComponent.split(separator: "-").first, !kept.contains(String(key)) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            if drew { WidgetCenter.shared.reloadAllTimelines() }
        }
    }

    /// One shape's pictures and where they are, written to the App Group; whether it worked.
    private static func paint(_ selection: Selection, loaded: (selection: Selection, stops: [Stop], tracks: [Track]),
                              shape: WidgetMapShape) async -> Bool {
        let route = loaded.tracks.flatMap { $0.segments.map { $0.map(\.coordinate) } }
        let stop = loaded.stops.first { $0.code == selection.stopCode }?.coordinate
        let points = (route.joined() + [stop].compactMap { $0 }).map(MKMapPoint.init)
        guard let first = points.first else { return false }
        var bounds = points.dropFirst().reduce(MKMapRect(origin: first, size: MKMapSize())) { $0.union(MKMapRect(origin: $1, size: MKMapSize())) }
        // A short route or a lone stop: at least a few blocks around it.
        let least = 1_200 / MKMetersPerMapPointAtLatitude(first.coordinate.latitude)
        if bounds.width < least { bounds = bounds.insetBy(dx: -(least - bounds.width) / 2, dy: 0) }
        if bounds.height < least { bounds = bounds.insetBy(dx: 0, dy: -(least - bounds.height) / 2) }
        // The route in its area of the picture (clear of what's laid over it), the picture around it.
        let area = shape.routeArea, size = shape.size
        let perPoint = max(bounds.width / (size.width * area.width), bounds.height / (size.height * area.height))
        let rect = MKMapRect(x: bounds.midX - (area.midX * size.width) * perPoint, y: bounds.midY - (area.midY * size.height) * perPoint,
                             width: size.width * perPoint, height: size.height * perPoint)
        for dark in [false, true] {
            guard let url = WidgetMaps.imageURL(selection, shape, dark: dark),
                  let image = await picture(rect: rect, size: size, dark: dark, route: loaded.tracks, city: selection.city, stop: stop),
                  let data = image.jpegData(compressionQuality: 0.82) else { return false }
            try? data.write(to: url, options: .atomic)
        }
        let info = WidgetMapInfo(rect: [rect.origin.x, rect.origin.y, rect.width, rect.height],
                                 stop: stop.map { [$0.latitude, $0.longitude] }, version: WidgetMapInfo.currentVersion)
        guard let url = WidgetMaps.infoURL(selection, shape), let data = try? JSONEncoder().encode(info) else { return false }
        try? data.write(to: url, options: .atomic)
        return true
    }

    private static func picture(rect: MKMapRect, size: CGSize, dark: Bool, route: [Track], city: City,
                                stop: CLLocationCoordinate2D?) async -> UIImage? {
        let options = MKMapSnapshotter.Options()
        options.mapRect = rect
        options.size = size
        options.scale = 3
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        options.preferredConfiguration = configuration
        options.traitCollection = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            snapshot.image.draw(at: .zero)
            let context = renderer.cgContext
            context.setLineCap(.round)
            context.setLineJoin(.round)
            // Each line in its color, the selected line's last, on top.
            for track in route.reversed() {
                let color = UIColor(Color(hex: LineBadge.color(of: track.lineID, in: city)?.hex) ?? LineBadge.red)
                // A light edge under the line, so it stands off the map.
                for (width, stroke) in [(5.0, UIColor.white.withAlphaComponent(dark ? 0.25 : 0.85)), (3.0, color)] {
                    context.setLineWidth(width)
                    context.setStrokeColor(stroke.cgColor)
                    for segment in track.segments where segment.count > 1 {
                        context.addLines(between: segment.map { snapshot.point(for: $0.coordinate) })
                    }
                    context.strokePath()
                }
            }
            if let stop {
                let at = snapshot.point(for: stop)
                let dot = CGRect(x: at.x - 5, y: at.y - 5, width: 10, height: 10)
                context.setFillColor(UIColor.white.cgColor)
                context.fillEllipse(in: dot.insetBy(dx: -1.5, dy: -1.5))
                context.setFillColor(UIColor.systemBlue.cgColor)
                context.fillEllipse(in: dot)
            }
        }
    }
}

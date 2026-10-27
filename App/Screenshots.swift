#if DEBUG
import SwiftUI
import WidgetKit

/// App Store screenshot support. Launch with `-screen <name>` to open a screen directly:
/// `lines` and `stops` open the picker, `map` the live map; `widgets` and `lock` show the widgets on a mock
/// Home Screen and Lock Screen (iOS doesn't let automation place real widgets); `lockwidget` is a
/// plain Lock Screen with just the clock and the rectangular widget, no captions.
enum ScreenshotScreen: String {
    case lines, stops, map, widgets, lock, lockwidget, guide

    static var current: ScreenshotScreen? {
        UserDefaults.standard.string(forKey: "screen").flatMap(ScreenshotScreen.init)
    }
}

extension ScreenshotScreen {
    /// Launched with `-seedFavorites YES` (see AppStore/capture.sh): replaces the favorites with a set
    /// worth showing in every city, and opens San Francisco.
    static func seedFavoritesIfAsked() {
        // `-seedCity nyc`: open that city's first favorite.
        if let city = UserDefaults.standard.string(forKey: "seedCity").flatMap(City.init(rawValue:)),
           let first = Selection.favorites.first(where: { $0.city == city }) {
            Selection.current = first
        }
        guard UserDefaults.standard.bool(forKey: "seedFavorites") else { return }
        let sf = City.sf.defaultSelection
        Selection.favorites = [
            sf,
            Selection(lineID: "14", lineName: "Mission", directionID: "IB", destination: "Ferry Plaza",
                      stopCode: "17841", stopName: "Mission St & Power St"),
            Selection(lineID: "N", lineName: "Judah", directionID: "OB", destination: "Ocean Beach",
                      stopCode: "14447", stopName: "Duboce Ave & Church St"),
            Selection(lineID: "Yellow", lineName: "BART", directionID: "S", destination: "San Francisco International Airport",
                      stopCode: "M50-1", stopName: "16th Street / Mission"),
            City.seattle.defaultSelection,
            City.nyc.defaultSelection,
            Selection(lineID: "B63", lineName: "Bay Ridge - Cobble Hill", directionID: "1", destination: "Bay Ridge Shore Rd via 5 Av",
                      stopCode: "MTA_308214", stopName: "5 Av/Union St", city: .nyc),
            Selection(lineID: "HOB–33", lineName: "PATH Hoboken - 33rd Street", directionID: "Y", destination: "33rd Street",
                      stopCode: "PHOBY", stopName: "Hoboken", city: .nyc),
        ]
        Selection.current = sf
    }
}

struct WidgetShowcase: View {
    let screen: ScreenshotScreen
    @Environment(\.colorScheme) private var colorScheme
    @State private var entry = DeparturesEntry.sample()

    var body: some View {
        Group {
            switch screen {
            case .lock: lockScreen
            case .lockwidget: plainLockScreen
            default: homeScreen
            }
        }
        .task {
            // The favorites with live times, like the real widget shows them.
            var rows = [WidgetRow]()
            for selection in Selection.widgetSelections(near: Selection.current.city).prefix(4) {
                let departures = (try? await TransitService.departures(for: selection, client: .app)) ?? []
                rows.append(WidgetRow(selection: selection, departures: departures))
            }
            if !rows.isEmpty { entry = DeparturesEntry(date: .now, rows: rows, error: nil) }
        }
    }

    private var homeScreen: some View {
        VStack(spacing: 28) {
            caption("Your next bus,\nright on your Home Screen")
            card(Bus37WidgetView(entry: entry, family: .systemMedium), width: 364, height: 170)
            HStack(spacing: 24) {
                card(Bus37WidgetView(entry: entry, family: .systemSmall), width: 170, height: 170)
                VStack(spacing: 6) {
                    Text("37")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(LineBadge.red, in: RoundedRectangle(cornerRadius: 16))
                    Text("37 Shades of Late").font(.caption).foregroundStyle(.white)
                }
                .frame(width: 170)
            }
            Spacer()
        }
        .padding(.top, 70)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: homeWallpaper,
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private var lockScreen: some View {
        VStack(spacing: 0) {
            caption("Glance at your Lock Screen\nbefore you head out")
                .padding(.top, 70)
                .padding(.bottom, 56)
            Bus37WidgetView(entry: entry, family: .accessoryInline)
                .font(.title3.weight(.semibold))
            Text(entry.date.formatted(Date.VerbatimFormatStyle(
                format: "\(hour: .defaultDigits(clock: .twelveHour, hourCycle: .oneBased)):\(minute: .twoDigits)",
                timeZone: .current, calendar: .current)))
                .font(.system(size: 104, weight: .bold, design: .rounded))
                .monospacedDigit()
            HStack(spacing: 14) {
                Bus37WidgetView(entry: entry, family: .accessoryRectangular)
                    .frame(width: 172, height: 76)
                Bus37WidgetView(entry: entry, family: .accessoryCircular)
                    .frame(width: 76, height: 76)
            }
            .padding(.top, 8)
            Spacer()
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: [Color(red: 0.05, green: 0.08, blue: 0.2), Color(red: 0.3, green: 0.12, blue: 0.3)],
                                   startPoint: .top, endPoint: .bottom))
    }

    /// Just what a real Lock Screen with the rectangular widget looks like: date, clock, widget.
    private var plainLockScreen: some View {
        VStack(spacing: 0) {
            Text(entry.date, format: .dateTime.weekday(.wide).month(.wide).day())
                .font(.system(size: 22, weight: .semibold))
                .padding(.top, 78)
            Text(entry.date.formatted(Date.VerbatimFormatStyle(
                format: "\(hour: .defaultDigits(clock: .twelveHour, hourCycle: .oneBased)):\(minute: .twoDigits)",
                timeZone: .current, calendar: .current)))
                .font(.system(size: 104, weight: .bold, design: .rounded))
                .monospacedDigit()
            Bus37WidgetView(entry: entry, family: .accessoryRectangular)
                .frame(width: 172, height: 76)
                .padding(.top, 8)
            Spacer()
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: [Color(red: 0.05, green: 0.08, blue: 0.2), Color(red: 0.3, green: 0.12, blue: 0.3)],
                                   startPoint: .top, endPoint: .bottom))
    }

    /// A dimmer wallpaper in dark mode, like iOS's own dark wallpapers.
    private var homeWallpaper: [Color] {
        colorScheme == .dark
            ? [Color(red: 0.05, green: 0.12, blue: 0.28), Color(red: 0.06, green: 0.3, blue: 0.34)]
            : [Color(red: 0.16, green: 0.42, blue: 0.75), Color(red: 0.36, green: 0.78, blue: 0.78)]
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 30, weight: .bold, design: .rounded))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
    }

    private func card(_ content: some View, width: CGFloat, height: CGFloat) -> some View {
        content
            .padding(16)
            .frame(width: width, height: height)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}
#endif

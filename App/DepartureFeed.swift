import SwiftUI
import WidgetKit

/// The live departures for the selected stop, shared by the departure list and both maps so
/// they always show the same data. It refreshes as soon as the proxy has a newer snapshot.
@MainActor @Observable
final class DepartureFeed {
    private(set) var departures: [Departure] = []
    private(set) var refresh: Refresh?
    private(set) var error: String?
    /// Which selection `departures` belong to; the list dims them while the next stop loads.
    private(set) var loaded: Selection?
    /// When `departures` last changed, for "in N min" labels that should match the data.
    private(set) var updatedAt = Date.now
    /// Who's looking, for the proxy's usage statistics: the full map, or the app's main screen.
    var client: Client = .app

    private var following: Selection?

    static let switchAnimation = Animation.snappy(duration: 0.3)

    /// Keeps `departures` current for `selection` until the calling task is cancelled.
    func follow(_ selection: Selection) async {
        following = selection
        var first = true
        while !Task.isCancelled {
            await load(selection, animated: first)
            if first {
                // A new stop: let the widgets show it too.
                WidgetCenter.shared.reloadAllTimelines()
                first = false
            }
            // Ask again as soon as the proxy's next snapshot is ready; if that time has passed
            // (its 511 budget is spent), retry every few seconds instead of hammering it.
            let next = refresh?.nextRefreshAt ?? .now
            try? await Task.sleep(for: .seconds(max(5, next.timeIntervalSinceNow + 0.5)))
        }
    }

    /// Fetches right away, e.g. for pull to refresh.
    func reload() async {
        guard let following else { return }
        await load(following, animated: false)
    }

    private func load(_ selection: Selection, animated: Bool) async {
        do {
            let latest = try await TransitService.snapshot(for: selection, client: client)
            guard !Task.isCancelled, following?.id == selection.id else { return }
            withAnimation(animated ? Self.switchAnimation : nil) {
                departures = latest.departures
                refresh = latest.refresh
                error = nil
                loaded = selection
                updatedAt = .now
            }
            // A stop being watched from the Dynamic Island gets the new times too.
            BusActivities.shared.update(selection, departures: latest.departures, fetchedAt: latest.refresh.fetchedAt)
        } catch {
            // Switching stops cancels the previous load; that's not an error to show.
            guard !Task.isCancelled, following?.id == selection.id else { return }
            withAnimation(animated ? Self.switchAnimation : nil) {
                self.error = error.localizedDescription
                loaded = selection
            }
        }
    }
}

/// Upcoming departures for every favorite, for the small rows in the favorites list. Refreshed
/// about every 70 seconds (the proxy's snapshot interval); the open stop has its own `DepartureFeed`.
@MainActor @Observable
final class FavoritesFeed {
    private(set) var departures: [Selection.ID: [Departure]] = [:]

    /// Keeps `departures` current for `favorites` until the calling task is cancelled.
    func follow(_ favorites: [Selection]) async {
        while !Task.isCancelled {
            await withTaskGroup(of: (Selection.ID, [Departure]?).self) { group in
                for favorite in favorites {
                    group.addTask { (favorite.id, try? await TransitService.departures(for: favorite, client: .app)) }
                }
                for await (id, latest) in group where !Task.isCancelled {
                    // Keep the last known times when a refresh fails (bad connection).
                    if let latest { departures[id] = latest }
                }
            }
            try? await Task.sleep(for: .seconds(70))
        }
    }
}

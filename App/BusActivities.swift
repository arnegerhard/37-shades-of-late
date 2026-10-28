import ActivityKit
import Foundation

/// Starts, updates and ends the Live Activities that watch a stop from outside the app. While the
/// app runs it updates them itself; otherwise the proxy does, with pushes to each one's token (and
/// ends them when they're over). Without the proxy, they count down on their own.
@MainActor @Observable
final class BusActivities {
    static let shared = BusActivities()

    /// The selections being watched, by id.
    private(set) var watching: Set<String> = []

    /// The activities whose push tokens go to the proxy, by id.
    private var following: Set<String> = []

    private init() {
        refreshWatching()
        // Tokens can change while an activity runs, also while the app wasn't.
        Activity<BusActivity>.activities.forEach(follow)
    }

    var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func isWatching(_ selection: Selection) -> Bool { watching.contains(selection.id) }

    /// Puts `selection`'s next departure on the Dynamic Island and the Lock Screen, instead of any
    /// other stop's: one at a time is plenty to worry about.
    func start(_ selection: Selection, departures: [Departure], fetchedAt: Date) {
        let now = Date.now
        guard let state = BusActivity.ContentState(departures: departures, since: now, fetchedAt: fetchedAt,
                                                   route: route(of: selection), stop: selection.stopCode) else { return }
        endAll()
        let attributes = BusActivity(selectionID: selection.id, line: selection.lineLabel, destination: selection.destination,
                                     stopName: selection.stopName, vehicle: selection.vehicle,
                                     link: selection.openURL, startedAt: now)
        if let activity = try? Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: state.ends),
                                               pushType: .token) {
            follow(activity)
        }
        refreshWatching()
    }

    func stop(_ selection: Selection) {
        for activity in Activity<BusActivity>.activities where activity.attributes.selectionID == selection.id {
            end(activity)
        }
        watching.remove(selection.id)
    }

    /// New times for `selection`, if it's being watched; ends it once it's over.
    func update(_ selection: Selection, departures: [Departure], fetchedAt: Date) {
        for activity in Activity<BusActivity>.activities where activity.attributes.selectionID == selection.id {
            guard let state = BusActivity.ContentState(departures: departures, since: activity.attributes.startedAt, fetchedAt: fetchedAt,
                                                       route: route(of: selection), stop: selection.stopCode),
                  state.ends > .now
            else {
                end(activity)
                watching.remove(selection.id)
                continue
            }
            Task { await activity.update(ActivityContent(state: state, staleDate: state.ends)) }
        }
    }

    /// Ends the activities that are over, for when the app comes back: they can't end themselves.
    func endFinished() {
        for activity in Activity<BusActivity>.activities where activity.content.state.ends <= .now {
            end(activity)
        }
        refreshWatching()
    }

    private func endAll() {
        for activity in Activity<BusActivity>.activities {
            end(activity)
        }
        watching = []
    }

    /// Ends `activity` now, and tells the proxy to stop pushing to it.
    private func end(_ activity: Activity<BusActivity>) {
        let token = activity.pushToken
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
            if let token { try? await TransitService.unwatch(token: token) }
        }
    }

    /// Sends `activity`'s push token to the proxy, now and whenever it changes.
    private func follow(_ activity: Activity<BusActivity>) {
        guard following.insert(activity.id).inserted,
              let selection = Selection(openURL: activity.attributes.link) else { return }
        Task {
            for await token in activity.pushTokenUpdates {
                try? await TransitService.watch(selection, token: token, startedAt: activity.attributes.startedAt)
            }
        }
    }

    /// The stops of `selection`'s line in its direction, from what's on the device, for how far the bus is.
    private func route(of selection: Selection) -> [Stop]? {
        TransitService.cachedDirections(for: Line(id: selection.lineID, name: "", mode: "bus"), in: selection.city)?
            .first { $0.id == selection.directionID }?.stops
    }

    private func refreshWatching() {
        watching = Set(Activity<BusActivity>.activities
            .filter { $0.activityState == .active && $0.content.state.ends > .now }
            .map(\.attributes.selectionID))
    }
}

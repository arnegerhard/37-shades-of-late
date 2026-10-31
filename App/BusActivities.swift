import ActivityKit
import SwiftUI
import TipKit

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
                                     link: selection.openURL, startedAt: now, round: selection.roundBadge,
                                     badges: selection.badgeParts, showsVehicles: selection.showsVehicles)
        if let activity = try? Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: state.ends),
                                               pushType: .token) {
            follow(activity)
        }
        refreshWatching()
    }

    /// Starts watching `selection`, or stops: what the watch buttons do. The preview in them fades
    /// into its outline (and back), and on starting, the island shows off what it got.
    func toggle(_ selection: Selection, departures: [Departure], fetchedAt: Date) {
        let wasWatching = isWatching(selection)
        withAnimation(.smooth(duration: 0.35)) {
            if wasWatching { stop(selection) } else { start(selection, departures: departures, fetchedAt: fetchedAt) }
        }
        // Taken off again, so they know how it goes; no need to point it out any more.
        if wasWatching, !isWatching(selection) { StalkTip.hasLetGo = true }
        if !wasWatching, isWatching(selection) {
            UIAccessibility.post(notification: .announcement, argument: Island.frame != nil ? "On your Dynamic Island" : "On your Lock Screen")
            IslandShowOff.shared.show(selection, departures: departures, fetchedAt: fetchedAt)
        }
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
    func route(of selection: Selection) -> [Stop]? {
        TransitService.cachedDirections(for: Line(id: selection.lineID, name: "", mode: "bus"), in: selection.city)?
            .first { $0.id == selection.directionID }?.stops
    }

    private func refreshWatching() {
        watching = Set(Activity<BusActivity>.activities
            .filter { $0.activityState == .active && $0.content.state.ends > .now }
            .map(\.attributes.selectionID))
    }
}

/// Where the Dynamic Island is, in the window: the same size on every iPhone that has one (those with
/// a safe area this tall); nil on the others.
enum Island {
    @MainActor static var frame: CGRect? {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        guard UIDevice.current.userInterfaceIdiom == .phone, let window, window.safeAreaInsets.top >= 51 else { return nil }
        return CGRect(x: window.bounds.width / 2 - 62.5, y: 11, width: 125, height: 37)
    }
}

/// The Dynamic Island as watching a stop makes it: the line on the left, the countdown on the right,
/// and in between, if there's room, what's under the camera. Without an island, it has the corners
/// of the Lock Screen's card instead, as that's where the watch goes.
struct IslandPill: View {
    let badges: [BadgePart]
    var round = false
    let next: Departure?
    /// The stop's name, say, where there's room for it.
    var middle: String? = nil
    var dimmed = false
    /// Up on the island already: only its outline is left here (with what it says, if `middle` has room).
    var lifted = false

    @Environment(\.colorScheme) private var colorScheme

    @MainActor static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Island.frame != nil ? 19 : 7, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 8) {
            // As on the island: a long badge ("1 Line") shrinks, the countdown never does.
            LineBadges(parts: badges, font: .system(.caption, design: .rounded).weight(.heavy), round: round)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let middle {
                // Gives way first, so the pill fits wherever it's put.
                Text(middle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .layoutPriority(-1)
            } else {
                Spacer(minLength: 0)
            }
            if let next {
                Countdown(date: next.time, from: .now)
                    .font(.system(.footnote, design: .rounded).weight(.heavy))
                    .foregroundStyle(next.isLive ? .green : .gray)
                    .fixedSize()
                    .opacity(dimmed ? 0.4 : 1)
            }
        }
        .padding(.horizontal, 9)
        .frame(maxHeight: .infinity)
        .background(lifted ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.black), in: Self.shape)
        .overlay {
            if lifted { Self.shape.strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])) }
        }
        .environment(\.colorScheme, lifted ? colorScheme : .dark)
        // The island's own text doesn't grow without end either.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }
}

/// The island just handed a watch, showing it off, as the system does when an activity has news: it
/// opens out to its expanded view (the real one, with the stop's times) with a tap of haptics, holds
/// a moment, and closes again. While the app is open the system doesn't show its own activity up
/// there, so this stands in for it, drawn over the real island, black on black.
@MainActor @Observable
final class IslandShowOff {
    static let shared = IslandShowOff()

    enum Phase { case closed, open }
    private(set) var phase: Phase?
    private(set) var attributes: BusActivity?
    private(set) var state: BusActivity.ContentState?

    func show(_ selection: Selection, departures: [Departure], fetchedAt: Date) {
        guard Island.frame != nil, !UIAccessibility.isReduceMotionEnabled else { return }
        let now = Date.now
        guard let state = BusActivity.ContentState(departures: departures, since: now, fetchedAt: fetchedAt,
                                                   route: BusActivities.shared.route(of: selection), stop: selection.stopCode)
        else { return }
        attributes = BusActivity(selectionID: selection.id, line: selection.lineLabel, destination: selection.destination,
                                 stopName: selection.stopName, vehicle: selection.vehicle, link: selection.openURL, startedAt: now,
                                 round: selection.roundBadge, badges: selection.badgeParts, showsVehicles: selection.showsVehicles)
        self.state = state
        phase = .closed
        // A turn later, so it's drawn closed (where the real island is) before it opens.
        DispatchQueue.main.async {
            // The tap as it opens: that's when it arrives.
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.spring(duration: 0.5, bounce: 0.3)) { self.phase = .open }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                withAnimation(.spring(duration: 0.45, bounce: 0.2)) {
                    self.phase = .closed
                } completion: {
                    self.phase = nil
                }
            }
        }
    }
}

/// Draws `IslandShowOff` over everything, at the island; goes over the whole window.
struct IslandShowOffView: View {
    private var showOff: IslandShowOff { .shared }

    var body: some View {
        if let phase = showOff.phase, let island = Island.frame {
            GeometryReader { geometry in
                let origin = geometry.frame(in: .global).origin
                // The expanded island: nearly the screen's width, tall enough for the camera's row and ours.
                let open = CGRect(x: 11, y: island.minY, width: geometry.size.width - 22, height: 104)
                let frame = phase == .open ? open : island
                let shape = RoundedRectangle(cornerRadius: phase == .open ? 44 : island.height / 2, style: .continuous)
                ZStack(alignment: .bottom) {
                    shape.fill(.black)
                    if let attributes = showOff.attributes, let state = showOff.state {
                        // Laid out at the open size throughout, so it doesn't reflow as the island moves;
                        // in after the island has mostly opened, out quickly before it closes.
                        BusActivityView(attributes: attributes, state: state, isStale: false)
                            .padding(.horizontal, 22)
                            .padding(.bottom, 14)
                            .frame(width: open.width, height: open.height, alignment: .bottom)
                            .scaleEffect(phase == .open ? 1 : 0.85, anchor: .top)
                            .opacity(phase == .open ? 1 : 0)
                            .animation(phase == .open ? .easeIn(duration: 0.25).delay(0.15) : .easeOut(duration: 0.12), value: phase)
                    }
                }
                .frame(width: frame.width, height: frame.height)
                .clipShape(shape)
                .position(x: frame.midX - origin.x, y: frame.midY - origin.y)
                .environment(\.colorScheme, .dark)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
}

/// Points out that the home map's pill goes up on the Dynamic Island (or the Lock Screen), from the
/// second visit with a favorite on the map until the first watch, from the pill or anywhere else.
struct StalkTip: Tip {
    /// Whether this iPhone has a Dynamic Island, for the wording.
    let island: Bool

    /// A new tip, under a new name, since it says how to take it off again too: everyone sees it once,
    /// whether or not they saw the one before.
    var id: String { "StalkTip.letGo" }

    static let homeWithFavorite = Event(id: "homeWithFavorite")
    /// Whether they've taken one off the island again: then they know both halves.
    @Parameter static var hasLetGo: Bool = false
    /// Whether Live Activities are on: without them, the pill just opens the map.
    @Parameter static var canWatch: Bool = false

    var title: Text { Text(island ? "Stalk it from any app" : "Stalk it from your Lock Screen") }
    var message: Text? {
        Text("Tap the pill to put it on your \(island ? "Dynamic Island" : "Lock Screen"). Tap it again to take it off.")
    }
    var image: Image? { Image(systemName: island ? "platter.filled.top.iphone" : "lock.iphone") }

    var rules: [Rule] {
        #Rule(Self.$hasLetGo) { $0 == false }
        #Rule(Self.$canWatch) { $0 == true }
        #Rule(Self.homeWithFavorite) { $0.donations.count >= 2 }
    }
}

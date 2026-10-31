import Foundation

/// How people get around the app: the screens they open and leave, the buttons they tap, where they put
/// the app away, and where it crashed, so the app can be made easier to use. Each is kept on the device
/// until the next request to the proxy, which carries a batch of them along (`header`, as X-Journey) and
/// records them under the install ID, like the requests themselves (see recordJourney in the proxy).
/// No stop, line or anything typed goes along: screen and button names only, and a city.
///
/// Sessions run from the app coming to the front to it going away; each gets a random ID of its own.
/// A session that ended without going away (the app was on screen when it stopped) crashed, there.
final class Journey: @unchecked Sendable {
    static let shared = Journey()

    /// One thing that happened, as it goes to the proxy: short keys, to keep the header small.
    struct Event: Codable {
        /// Its number, to take it off the queue once the proxy has it.
        var i: Int
        /// When, in seconds since 1970.
        var t: Int
        /// What: "open", "screen", "tap", "exit" or "crash".
        var k: String
        /// Which screen or button.
        var n: String
        /// More about it: how the app was opened, a button's choice, a crash's kind.
        var d: String?
        /// The screen it happened on, or came from.
        var f: String?
        /// The session.
        var s: String
        /// The city open at the time.
        var c: String?
        /// Seconds: on the screen it came from, or the session's length.
        var x: Int?
    }

    private let lock = NSLock()
    private let defaults = UserDefaults.standard
    private var queue: [Event]
    private var sending: Set<Int> = []
    private var next: Int
    private var session = Journey.newSession()
    private var sessionStart = Date.now
    /// Whether a session has begun since launch: the first keeps the ID the screens shown as the app
    /// launched (a moment before it says it's in front) were recorded under.
    private var begun = false
    /// The screens open, the one in front last, and since when it's been in front.
    private var screens: [String] = []
    private var shownAt = Date.now
    /// The screen last left with none in front of it.
    private var left: String?
    private var city: String?
    /// The most kept: past this, the oldest go (an install offline for weeks).
    private static let most = 500
    /// The most a request carries.
    private static let perRequest = 30

    private init() {
        queue = (defaults.data(forKey: "journey").flatMap { try? JSONDecoder().decode([Event].self, from: $0) }) ?? []
        // Numbers go on from launch to launch: the proxy keeps an install's event once per number.
        next = max(defaults.integer(forKey: "journeyNext"), (queue.map(\.i).max() ?? 0) + 1)
    }

    private static func newSession() -> String { String(UUID().uuidString.prefix(8)).lowercased() }

    // MARK: - What happened

    /// The app came to the front: `how` it was opened ("launch", "resume", "widget", "link"…). If it
    /// was on screen when it last stopped, without going away first, that was a crash.
    func opened(_ how: String) {
        lock.withLock {
            if defaults.bool(forKey: "journeyOnScreen") {
                add("crash", defaults.string(forKey: "journeyScreen") ?? "unknown", detail: defaults.string(forKey: "journeyTap"),
                    session: defaults.string(forKey: "journeySession") ?? session)
            }
            if begun {
                session = Self.newSession()
                sessionStart = .now
                shownAt = .now
            }
            begun = true
            add("open", how, from: screens.last)
            remember(onScreen: true)
        }
    }

    /// The app went away: where from, and after how long.
    func closed() {
        lock.withLock {
            add("exit", screens.last ?? "unknown", seconds: Date.now.timeIntervalSince(sessionStart))
            remember(onScreen: false)
        }
    }

    /// A screen came up: `name` ("home", "livemap"…), and in front of which.
    func show(_ name: String, detail: String? = nil) {
        lock.withLock {
            let from = screens.last ?? left
            screens.removeAll { $0 == name }
            screens.append(name)
            left = nil
            arrive(at: name, from: from, detail: detail)
        }
    }

    /// A screen went away; the one under it is in front again. (Pushing a screen can take the one under
    /// it away too: the next to show then comes from the one left.)
    func hide(_ name: String) {
        lock.withLock {
            guard screens.last == name else { screens.removeAll { $0 == name }; return }
            screens.removeLast()
            if let back = screens.last { arrive(at: back, from: name, detail: "back") } else { left = name }
        }
    }

    /// A button was tapped, on the screen in front: `name` ("favorite.add"…) and what it chose.
    func tap(_ name: String, _ detail: String? = nil) {
        lock.withLock {
            add("tap", name, detail: detail, from: screens.last)
            defaults.set(detail.map { "\(name) \($0)" } ?? name, forKey: "journeyTap")
        }
    }

    /// A crash or hang the system reported after the fact (MetricKit): `kind` "crash" or "hang", and what
    /// it was ("EXC_BREAKPOINT SIGTRAP", "4s").
    func diagnosed(_ kind: String, _ what: String, detail: String?) {
        lock.withLock { add(kind, "report", detail: [what, detail].compactMap { $0 }.joined(separator: " · ")) }
    }

    /// The city open, sent with what happens from now on.
    func setCity(_ city: String) { lock.withLock { self.city = city } }

    private func arrive(at name: String, from: String?, detail: String?) {
        add("screen", name, detail: detail, from: from, seconds: Date.now.timeIntervalSince(shownAt))
        shownAt = .now
        defaults.set(name, forKey: "journeyScreen")
    }

    private func add(_ kind: String, _ name: String, detail: String? = nil, from: String? = nil, seconds: TimeInterval? = nil, session: String? = nil) {
        queue.append(Event(i: next, t: Int(Date.now.timeIntervalSince1970), k: kind, n: name, d: detail, f: from,
                           s: session ?? self.session, c: city, x: seconds.map { Int($0.rounded()) }))
        next += 1
        defaults.set(next, forKey: "journeyNext")
        if queue.count > Self.most { queue.removeFirst(queue.count - Self.most) }
        save()
    }

    private func remember(onScreen: Bool) {
        defaults.set(onScreen, forKey: "journeyOnScreen")
        defaults.set(session, forKey: "journeySession")
    }

    private func save() { defaults.set(try? JSONEncoder().encode(queue), forKey: "journey") }

    // MARK: - Sending

    /// The next batch for a request to carry, and its numbers, to `delivered` once the proxy has them;
    /// nil when there's nothing to send.
    func header() -> (value: String, ids: [Int])? {
        lock.withLock {
            let batch = Array(queue.filter { !sending.contains($0.i) }.prefix(Self.perRequest))
            guard !batch.isEmpty, let data = try? JSONEncoder().encode(batch), let value = String(data: data, encoding: .utf8) else { return nil }
            sending.formUnion(batch.map(\.i))
            return (value, batch.map(\.i))
        }
    }

    /// The proxy has them (`ok`), or the request failed and they go again with the next one.
    func delivered(_ ids: [Int], ok: Bool) {
        lock.withLock {
            sending.subtract(ids)
            guard ok else { return }
            let sent = Set(ids)
            queue.removeAll { sent.contains($0.i) }
            save()
        }
    }

    /// Whether anything is waiting to go.
    var hasWaiting: Bool { lock.withLock { !queue.isEmpty } }
}

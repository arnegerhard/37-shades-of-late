import MetricKit
import SwiftUI

extension View {
    /// Marks this as a screen people get to, `name`, for Journey: it's in front while it's on screen.
    func journeyScreen(_ name: String, _ detail: String? = nil) -> some View {
        onAppear { Journey.shared.show(name, detail: detail) }
            .onDisappear { Journey.shared.hide(name) }
    }

    /// Tells Journey when the app comes to the front and goes away (a session), and sends what's waiting
    /// as it goes, while the system still gives it a moment.
    func journeySessions() -> some View {
        modifier(JourneySessions())
    }
}

private struct JourneySessions: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @State private var launched = false

    func body(content: Content) -> some View {
        content.onChange(of: scenePhase, initial: true) {
            switch scenePhase {
            case .active:
                Journey.shared.opened(launched ? "resume" : "launch")
                launched = true
                // What's waiting since last time (a crash, say), soon after opening, should no request
                // come along to carry it (no favorites yet, say).
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    await TransitService.sendJourney()
                }
            // Only once it's been in front: launching, the app can pass through the background first.
            case .background where launched:
                Journey.shared.closed()
                let task = UIApplication.shared.beginBackgroundTask()
                Task {
                    await TransitService.sendJourney()
                    UIApplication.shared.endBackgroundTask(task)
                }
            default: break
            }
        }
    }
}

/// Crashes and hangs as the system reports them (MetricKit), a launch or so after they happen: what
/// kind, for Journey. Where they happened is the screen Journey had in front when the app stopped.
final class SystemDiagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = SystemDiagnostics()

    func start() { MXMetricManager.shared.add(self) }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                let kind = [crash.exceptionType.map { Self.exceptions[$0.intValue] ?? "exception \($0)" },
                            crash.signal.map { Self.signals[$0.intValue] ?? "signal \($0)" }].compactMap { $0 }.joined(separator: " ")
                Journey.shared.diagnosed("crash", kind.isEmpty ? "unknown" : kind,
                                         detail: crash.terminationReason.map { String($0.prefix(60)) })
            }
            for hang in payload.hangDiagnostics ?? [] {
                let seconds = hang.hangDuration.converted(to: .seconds).value
                Journey.shared.diagnosed("hang", String(format: "%.0fs", seconds), detail: nil)
            }
        }
    }

    /// The usual ones, as crash logs name them: a Swift trap (a force unwrap, an index out of range) is a breakpoint.
    private static let exceptions = [1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 5: "EXC_SOFTWARE", 6: "EXC_BREAKPOINT", 10: "EXC_CRASH", 11: "EXC_RESOURCE", 12: "EXC_GUARD"]
    private static let signals = [4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV"]
}

import SwiftUI
import WidgetKit

/// First-launch walkthrough for adding the Lock Screen widget. iOS has no way for an app to add a
/// widget itself, so each step shows a drawn iPhone doing exactly what the user's will do,
/// with an animated finger on the spot to touch.
struct WidgetGuide: View {
    let onDone: () -> Void

    @State private var page = 0
    private let steps = Step.allCases

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip") { Journey.shared.tap("guide.skip", "step \(page + 1)"); onDone() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .opacity(page == steps.count - 1 ? 0 : 1)

            TabView(selection: $page) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    StepPage(step: step, number: index).tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack(spacing: 8) {
                ForEach(steps.indices, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? LineBadge.red : Color.secondary.opacity(0.35))
                        .frame(width: index == page ? 22 : 8, height: 8)
                }
            }
            .animation(.snappy, value: page)
            .padding(.bottom, 20)

            Button {
                if page < steps.count - 1 {
                    Journey.shared.tap("guide.next", "step \(page + 1)")
                    withAnimation(.snappy) { page += 1 }
                } else {
                    Journey.shared.tap("guide.done")
                    onDone()
                }
            } label: {
                Text(steps[page].button)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(LineBadge.red)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .background(Color(.systemBackground))
        .preferredColorScheme(.dark)
        .journeyScreen("guide")
        // Swiping between steps, as well as the button.
        .onChange(of: page) { Journey.shared.show("guide", detail: "step \(page + 1)") }
    }
}

// MARK: - Steps

private enum Step: CaseIterable {
    case intro, hold, customize, lockScreen, area, pick, done

    var title: String {
        switch self {
        case .intro: "Be let down without unlocking"
        case .hold: "Press and hold the Lock Screen"
        case .customize: "Tap Customize"
        case .lockScreen: "Choose the Lock Screen"
        case .area: "Tap under the clock"
        case .pick: "Pick 37 Shades of Late"
        case .done: "Tap Done. That's it."
        }
    }

    var detail: String {
        switch self {
        case .intro: "The best part of this app isn't in the app. Raise your phone, see the minutes, put it back. Setup takes 30 seconds, which is less than you'll wait for anything here."
        case .hold: "Wake your iPhone and let Face ID unlock it, but don't swipe up. Then press anywhere until the screen shrinks. Firmly, like you've been waiting a while."
        case .customize: "Bottom of the screen. It's been there the whole time."
        case .lockScreen: "Lock Screen on the left, Home Screen on the right. Tap the left one."
        case .area: "It may say Add Widgets. Already full? Remove one with the minus. Your ride deserves the space."
        case .pick: "Scroll or search, then tap the wide widget: all your favorites, with the minutes until each one shows."
        case .done: "Top right. Your Lock Screen now does the waiting for you, in the order of your favorites."
        }
    }

    var button: String {
        switch self {
        case .intro: "Show me how"
        case .done: "Start waiting"
        default: "Next"
        }
    }
}

private struct StepPage: View {
    let step: Step
    let number: Int

    var body: some View {
        VStack(spacing: 22) {
            MockPhone(step: step)
                .frame(maxHeight: .infinity)
            VStack(spacing: 10) {
                if number > 0 && step != .done {
                    Text("STEP \(number)")
                        .font(.caption.weight(.heavy))
                        .tracking(1.5)
                        .foregroundStyle(LineBadge.red)
                }
                Text(step.title)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(step.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            // At least as tall as most steps need, so the phone above doesn't jump between pages;
            // with large text it grows and the phone shrinks instead of cutting off the title.
            .frame(minHeight: 150, alignment: .top)
            .layoutPriority(1)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - The drawn iPhone

/// A small iPhone showing what each step looks like, with a pulsing finger where to touch.
private struct MockPhone: View {
    let step: Step

    private var entry: DeparturesEntry { .sample() }

    var body: some View {
        GeometryReader { geometry in
            let height = min(geometry.size.height, 440)
            let width = height * 0.49
            ZStack {
                screen
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: width * 0.16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: width * 0.16, style: .continuous)
                        .strokeBorder(Color(white: 0.35), lineWidth: 5))
                    .overlay(alignment: .top) {
                        Capsule().fill(.black).frame(width: width * 0.32, height: 18).padding(.top, 12)
                    }
                    .shadow(color: .black.opacity(0.6), radius: 20, y: 10)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var wallpaper: some View {
        LinearGradient(colors: [Color(red: 0.05, green: 0.08, blue: 0.22), Color(red: 0.32, green: 0.12, blue: 0.3)],
                       startPoint: .top, endPoint: .bottom)
    }

    @ViewBuilder private var screen: some View {
        switch step {
        case .intro, .done: lockScreen(widget: true, editing: false)
        case .hold: lockScreen(widget: false, editing: false).overlay { Finger(hold: true).offset(y: 40) }
        case .customize: switcher
        case .lockScreen: switcher.overlay { Finger().offset(x: -46, y: -20) }
        case .area: lockScreen(widget: false, editing: true).overlay { Finger().offset(y: -18) }
        case .pick: gallery
        }
    }

    /// The Lock Screen: date, clock, and either the widget or the empty space for it.
    private func lockScreen(widget: Bool, editing: Bool) -> some View {
        ZStack {
            wallpaper
            VStack(spacing: 2) {
                Text("Monday, October 26").font(.system(size: 11, weight: .semibold))
                Text("9:41").font(.system(size: 56, weight: .bold, design: .rounded))
                if widget {
                    Bus37WidgetView(entry: entry, family: .accessoryRectangular)
                        .frame(width: 150, height: 66)
                        .environment(\.colorScheme, .dark)
                        .padding(.top, 2)
                } else {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.white.opacity(editing ? 0.9 : 0), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(editing ? 0.15 : 0)))
                        .overlay {
                            if editing {
                                Label("Add Widgets", systemImage: "plus").font(.system(size: 10, weight: .semibold))
                            }
                        }
                        .frame(width: 150, height: 52)
                        .padding(.top, 4)
                }
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.top, editing ? 58 : 44)
            if editing {
                VStack {
                    HStack {
                        Spacer()
                        Text("Done").font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.white.opacity(0.25), in: Capsule())
                    }
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.top, 34)
            }
        }
    }

    private func thumbnail(width: CGFloat) -> some View {
        lockScreen(widget: false, editing: false)
            .frame(width: 215, height: 440)
            .scaleEffect(width / 215)
            .frame(width: width, height: width * 440 / 215)
            .clipShape(RoundedRectangle(cornerRadius: width * 0.12))
    }

    /// After the long press: the Lock Screen shrunk, with Customize below; then Lock vs Home Screen.
    private var switcher: some View {
        ZStack {
            Color(white: 0.08)
            VStack(spacing: 14) {
                if step == .customize {
                    thumbnail(width: 128)
                        .padding(.top, 20)
                    Text("Customize")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 22).padding(.vertical, 8)
                        .background(.white.opacity(0.18), in: Capsule())
                        .overlay(alignment: .trailing) { Finger().offset(x: 14) }
                } else {
                    HStack(spacing: 8) {
                        thumbnail(width: 84)
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white, lineWidth: 2))
                        LinearGradient(colors: [.teal.opacity(0.7), .blue.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(Text("Home\nScreen").font(.system(size: 9, weight: .semibold)).multilineTextAlignment(.center))
                            .frame(width: 84, height: 84 * 440 / 215)
                    }
                    .padding(.top, 50)
                    Text("Lock Screen").font(.system(size: 10, weight: .semibold)).offset(x: -46)
                }
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.top, 30)
        }
    }

    /// The widget gallery sheet with this app's wide widget offered.
    private var gallery: some View {
        ZStack(alignment: .bottom) {
            lockScreen(widget: false, editing: true).blur(radius: 2)
            VStack(alignment: .leading, spacing: 10) {
                Capsule().fill(.white.opacity(0.4)).frame(width: 36, height: 4).frame(maxWidth: .infinity)
                Text("Add Widgets").font(.system(size: 13, weight: .bold))
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 6).fill(LineBadge.red).frame(width: 24, height: 24)
                        .overlay(Text("37").font(.system(size: 10, weight: .heavy, design: .rounded)))
                    Text("37 Shades of Late").font(.system(size: 12, weight: .semibold))
                }
                Bus37WidgetView(entry: entry, family: .accessoryRectangular)
                    .frame(width: 150, height: 62)
                    .padding(8)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    .environment(\.colorScheme, .dark)
                    .overlay(alignment: .bottomTrailing) { Finger().offset(x: 6, y: 6) }
                HStack(spacing: 8) {
                    Circle().fill(.white.opacity(0.12)).frame(width: 52, height: 52)
                        .overlay(Text("37\n8m").font(.system(size: 9, weight: .bold)).multilineTextAlignment(.center))
                    Text("…or the round one for just your open stop")
                        .font(.system(size: 9)).foregroundStyle(.white.opacity(0.7))
                }
            }
            .foregroundStyle(.white)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.16), in: UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22))
        }
    }
}

/// A fingertip that taps (or presses and holds) its spot, over and over.
private struct Finger: View {
    var hold = false

    @State private var down = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(down ? 0 : 0.8), lineWidth: 2)
                .frame(width: down ? 64 : 30, height: down ? 64 : 30)
            Circle()
                .fill(.white.opacity(0.85))
                .frame(width: 26, height: 26)
                .scaleEffect(down ? 0.8 : 1)
                .shadow(color: .black.opacity(0.4), radius: 4)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: hold ? 1.4 : 0.8).repeatForever(autoreverses: true)) { down = true }
        }
    }
}

extension WidgetGuide {
    /// Shown once, on the first launch after this version is installed.
    static var hasBeenShown: Bool {
        get {
            #if DEBUG
            // Screenshot runs open a specific screen; don't cover it with the guide.
            if UserDefaults.standard.string(forKey: "screen") != nil { return true }
            #endif
            return UserDefaults.standard.bool(forKey: "widgetGuideShown")
        }
        set { UserDefaults.standard.set(newValue, forKey: "widgetGuideShown") }
    }
}

import SwiftUI
import WidgetKit

@main
struct Bus37App: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let screen = ScreenshotScreen.current, screen == .widgets || screen == .lock {
                WidgetShowcase(screen: screen)
            } else {
                ContentView()
            }
            #else
            ContentView()
            #endif
        }
    }
}

struct ContentView: View {
    @State private var selection = Selection.current
    @State private var departures: [Departure] = []
    @State private var error: String?
    @State private var choosing = false
    @State private var pickerPath: [Line] = []
    @State private var showingMap = false
    @State private var favorites = Selection.favorites
    /// Which selection `departures` belong to; they dim while the next stop's times load.
    @State private var loaded: Selection?

    private var isStale: Bool { loaded?.id != selection.id }

    private var isFavorite: Bool { favorites.contains { $0.id == selection.id } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { choosing = true } label: {
                        HStack(spacing: 12) {
                            LineBadge(line: selection.lineID, font: .system(.title3, design: .rounded).weight(.heavy))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("To \(selection.destination)").font(.headline)
                                Text(selection.stopName).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("Change").font(.subheadline).foregroundStyle(Color.accentColor)
                        }
                    }
                    .tint(.primary)
                } footer: {
                    Text("Your widgets show this line and stop.")
                }

                Section {
                    if let error {
                        Text(error).foregroundStyle(.secondary)
                    } else if departures.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No upcoming \((loaded ?? selection).lineID)s")
                                .foregroundStyle(.secondary)
                            QuipText(Quip.noPrediction(line: (loaded ?? selection).lineID))
                        }
                        .opacity(isStale ? 0.4 : 1)
                    }
                    ForEach(departures, id: \.self) { departure in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(departure.time, format: .dateTime.hour().minute())
                                    .font(.title3.weight(.semibold)).monospacedDigit()
                                Spacer()
                                Text(departure.time, style: .relative)
                                    .foregroundStyle(departure.isLive ? .green : .secondary)
                            }
                            // Only the next bus gets commentary.
                            if departure == departures.first {
                                TimelineView(.everyMinute) { context in
                                    QuipText(Quip.forWait(until: departure.time, from: context.date,
                                                          line: (loaded ?? selection).lineID))
                                }
                            }
                        }
                        .opacity(isStale ? 0.4 : 1)
                    }
                } header: {
                    HStack {
                        Text("Next departures")
                        Spacer()
                        Button(isFavorite ? "Saved" : "Save", systemImage: isFavorite ? "star.fill" : "star") {
                            toggleFavorite()
                        }
                        .font(.subheadline.weight(.semibold))
                        .tint(.orange)
                    }
                    .textCase(nil)
                }

                Section {
                    Button { showingMap = true } label: {
                        RouteMap(selection: selection, interactive: false)
                            .frame(height: 200)
                            .allowsHitTesting(false)
                            .overlay(alignment: .bottomTrailing) {
                                Label("Live map", systemImage: "arrow.up.left.and.arrow.down.right")
                                    .font(.footnote.weight(.semibold))
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(.regularMaterial, in: Capsule())
                                    .padding(10)
                            }
                    }
                    .listRowInsets(EdgeInsets())
                }

                Section {
                    if favorites.isEmpty {
                        Label("Tap Save above to keep this line and stop here.", systemImage: "star")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(favorites) { favorite in
                        Button { select(favorite) } label: { favoriteRow(favorite) }
                            .tint(.primary)
                            .listRowBackground(favoriteBackground(
                                isSelected: favorite.id == selection.id,
                                isFirst: favorite.id == favorites.first?.id,
                                isLast: favorite.id == favorites.last?.id))
                    }
                    .onDelete { favorites.remove(atOffsets: $0) }
                    .onMove { favorites.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Favorites").textCase(nil)
                } footer: {
                    if !favorites.isEmpty {
                        Text("Tap a favorite to show it here and on your widgets. Hold and drag to reorder, swipe to delete.")
                    }
                }

                Section {
                    Text("Add the widget from your Home Screen or Lock Screen: touch and hold, tap Edit or Customize, then search for \"37 Shades of Late\".")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("37 Shades of Late")
            .refreshable { await load() }
            .navigationDestination(isPresented: $showingMap) {
                RouteMap(selection: selection)
                    .navigationTitle("\(selection.lineID) \(selection.lineName)")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.visible, for: .navigationBar)
            }
            .task(id: selection) { await load() }
            .onChange(of: favorites) { Selection.favorites = favorites }
            #if DEBUG
            .onAppear {
                switch ScreenshotScreen.current {
                case .lines: choosing = true
                case .map: showingMap = true
                case .stops:
                    choosing = true
                    pickerPath = [Line(id: selection.lineID, name: selection.lineName, mode: "bus")]
                default: break
                }
            }
            #endif
            .sheet(isPresented: $choosing) {
                NavigationStack(path: $pickerPath) {
                    LinePicker { picked in
                        select(picked)
                        choosing = false
                        pickerPath = []
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { choosing = false } }
                    }
                }
            }
        }
    }

    private func favoriteRow(_ favorite: Selection) -> some View {
        HStack(spacing: 12) {
            LineBadge(line: favorite.lineID, font: .system(.body, design: .rounded).weight(.heavy))
                .frame(minWidth: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text("To \(favorite.destination)").font(.subheadline.weight(.semibold))
                Text(favorite.stopName).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .accessibilityAddTraits(favorite.id == selection.id ? .isSelected : [])
    }

    /// The favorite shown on the widgets gets a thin frame in the line-badge red.
    private func favoriteBackground(isSelected: Bool, isFirst: Bool, isLast: Bool) -> some View {
        Color(.secondarySystemGroupedBackground)
            .overlay {
                if isSelected { SelectedFavoriteFrame(isFirst: isFirst, isLast: isLast) }
            }
    }

    /// Makes `picked` the line and stop shown in the app and on the widgets.
    private func select(_ picked: Selection) {
        guard picked.id != selection.id else { return }
        Selection.current = picked
        // Keep the old times on screen (dimmed) until the new ones arrive, so the list
        // resizes once, straight to its new height.
        withAnimation(Self.switchAnimation) { selection = picked }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func toggleFavorite() {
        if let index = favorites.firstIndex(where: { $0.id == selection.id }) {
            favorites.remove(at: index)
        } else {
            favorites.append(selection)
        }
    }

    private static let switchAnimation = Animation.snappy(duration: 0.3)

    private func load() async {
        let target = selection
        do {
            let latest = try await TransitService.departures(for: selection, client: .app)
            withAnimation(Self.switchAnimation) {
                departures = latest
                error = nil
                loaded = target
            }
        } catch {
            // Switching stops cancels the previous load; that's not an error to show.
            guard !Task.isCancelled else { return }
            withAnimation(Self.switchAnimation) {
                self.error = error.localizedDescription
                loaded = target
            }
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// Thin red outline for the favorite shown on the widgets. The first and last rows sit in the
/// section's rounded corners, so their outer corners follow those instead of being clipped.
private struct SelectedFavoriteFrame: View {
    let isFirst: Bool
    let isLast: Bool

    private static let inset: CGFloat = 2
    private static let innerRadius: CGFloat = 12

    /// Inset-grouped sections round their corners by about 26pt on iOS 26 and 10pt before.
    /// SwiftUI doesn't expose the value (and ConcentricRectangle doesn't see the row's
    /// container), so it's matched by hand.
    private static var outerRadius: CGFloat {
        if #available(iOS 26, *) { 26 - inset } else { innerRadius }
    }

    var body: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? Self.outerRadius : Self.innerRadius,
            bottomLeadingRadius: isLast ? Self.outerRadius : Self.innerRadius,
            bottomTrailingRadius: isLast ? Self.outerRadius : Self.innerRadius,
            topTrailingRadius: isFirst ? Self.outerRadius : Self.innerRadius,
            style: .continuous
        )
        .strokeBorder(LineBadge.red.opacity(0.7), lineWidth: 2)
        .padding(Self.inset)
    }
}

/// Editorial commentary on the wait, shown in small text under predictions in the app
/// (never on widgets).
enum Quip {
    static func forWait(until time: Date, from now: Date = .now, line: String) -> String {
        switch Int(time.timeIntervalSince(now) / 60) {
        case ..<4: "Holy shit, the \(line) is real."
        case ..<9: "Stay put, lazy bastard."
        case ..<16: "Make coffee. Reconsider your life."
        default: "Walking is starting to look attractive."
        }
    }

    static func noPrediction(line: String) -> String {
        "Schrödinger's \(line): both coming and not coming."
    }

    static func vanished(line: String) -> String {
        "The \(line) has entered the witness protection program."
    }
}

struct QuipText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .italic()
            .foregroundStyle(.secondary)
    }
}

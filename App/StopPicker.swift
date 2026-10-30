import SwiftUI

/// Pick a city and line, then a direction and stop. Calls `onPick` with the finished selection.
struct LinePicker: View {
    let onPick: (Selection) -> Void

    @State private var city = Selection.current.city
    @State private var lines: [Line] = []
    @State private var error: String?
    @State private var search = ""
    // The map is the main way to pick; the toolbar button switches to the searchable list.
    @State private var showingMap = true

    private var filtered: [Line] {
        guard !search.isEmpty else { return lines }
        return lines.filter { $0.id.localizedCaseInsensitiveContains(search) || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        Group {
            if showingMap {
                LineMapPicker(city: city, onPick: onPick)
                    .safeAreaInset(edge: .top) {
                        cityPicker
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .background(.bar)
                    }
            } else {
                list
            }
        }
        .navigationTitle("Pick your poison")
        .navigationBarTitleDisplayMode(showingMap ? .inline : .automatic)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.snappy(duration: 0.3)) { showingMap.toggle() }
                } label: {
                    Label(showingMap ? "List" : "Map", systemImage: showingMap ? "list.bullet" : "map")
                }
            }
        }
        .navigationDestination(for: Line.self) { line in
            StopPicker(line: line, city: city, onPick: onPick)
        }
        .task(id: city) {
            lines = []
            error = nil
            lines = TransitService.cachedLines(in: city)
            if lines.isEmpty { error = "No line data yet. Your connection is running late too." }
            if let newer = await TransitService.refreshedLines(in: city), !Task.isCancelled {
                lines = newer
                error = nil
            }
        }
    }

    private var cityPicker: some View {
        Picker("City", selection: $city) {
            ForEach(City.allCases) { Text($0.shortName).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private var list: some View {
        List {
            Section {
                cityPicker
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            ForEach(filtered) { line in
                NavigationLink(value: line) {
                    HStack(spacing: 10) {
                        LineBadge(line: LineBadge.short(line.id, in: city), font: .system(.body, design: .rounded).weight(.heavy),
                                  round: LineBadge.isRound([line.id], in: city), spoken: line.id)
                            .frame(minWidth: 52, alignment: .leading)
                        Text(line.name)
                    }
                }
            }
        }
        .overlay {
            if let error {
                ContentUnavailableView("The lines didn't show up", systemImage: "wifi.exclamationmark", description: Text(error))
            } else if lines.isEmpty {
                ProgressView()
            }
        }
        .searchable(text: $search, prompt: "Line number or name")
    }
}

struct StopPicker: View {
    let line: Line
    let city: City
    let onPick: (Selection) -> Void

    @State private var directions: [Direction] = []
    @State private var directionID: String?
    @State private var error: String?
    @State private var search = ""

    private var direction: Direction? { directions.first { $0.id == directionID } ?? directions.first }

    private var stops: [Stop] {
        let stops = direction?.stops ?? []
        guard !search.isEmpty else { return stops }
        return stops.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.code.contains(search) }
    }

    var body: some View {
        List {
            if directions.count > 1 {
                Picker("Direction", selection: Binding(get: { direction?.id }, set: { directionID = $0 })) {
                    ForEach(directions) { Text("To \($0.destination)").tag(Optional($0.id)) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section("Stops") {
                ForEach(stops) { stop in
                    Button {
                        guard let direction else { return }
                        onPick(Selection(
                            lineID: line.id, lineName: line.name, directionID: direction.id,
                            destination: direction.destination, stopCode: stop.code, stopName: stop.name,
                            city: city))
                    } label: {
                        Text(stop.name)
                    }
                    .tint(.primary)
                }
            }
        }
        .overlay {
            if let error {
                ContentUnavailableView("The stops didn't show up", systemImage: "wifi.exclamationmark", description: Text(error))
            } else if directions.isEmpty {
                ProgressView()
            }
        }
        .searchable(text: $search, prompt: "Street name, if you know it")
        .navigationTitle("\(line.id) \(line.name)")
        .task {
            do {
                directions = try await TransitService.directions(for: line, in: city)
                // Reopening the current line starts on the direction you already ride.
                let current = Selection.current
                if directionID == nil, current.city == city, current.lineID == line.id {
                    directionID = directions.first { $0.id == current.directionID }?.id
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

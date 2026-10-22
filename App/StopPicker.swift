import SwiftUI

/// Pick a city and line, then a direction and stop. Calls `onPick` with the finished selection.
struct LinePicker: View {
    let onPick: (Selection) -> Void

    @State private var city = Selection.current.city
    @State private var lines: [Line] = []
    @State private var error: String?
    @State private var search = ""

    private var filtered: [Line] {
        guard !search.isEmpty else { return lines }
        return lines.filter { $0.id.localizedCaseInsensitiveContains(search) || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            Section {
                Picker("City", selection: $city) {
                    ForEach(City.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            ForEach(filtered) { line in
                NavigationLink(value: line) {
                    HStack(spacing: 10) {
                        LineBadge(line: line.id, font: .system(.body, design: .rounded).weight(.heavy))
                            .frame(minWidth: 52, alignment: .leading)
                        Text(line.name)
                    }
                }
            }
        }
        .overlay {
            if let error {
                ContentUnavailableView("Couldn't load lines", systemImage: "wifi.exclamationmark", description: Text(error))
            } else if lines.isEmpty {
                ProgressView()
            }
        }
        .searchable(text: $search, prompt: "Line number or name")
        .navigationTitle("Choose a line")
        .navigationDestination(for: Line.self) { line in
            StopPicker(line: line, city: city, onPick: onPick)
        }
        .task(id: city) {
            lines = []
            error = nil
            do { lines = try await TransitService.lines(in: city) } catch { self.error = error.localizedDescription }
        }
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
                ContentUnavailableView("Couldn't load stops", systemImage: "wifi.exclamationmark", description: Text(error))
            } else if directions.isEmpty {
                ProgressView()
            }
        }
        .searchable(text: $search, prompt: "Street name")
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

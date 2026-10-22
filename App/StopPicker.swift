import SwiftUI

/// Pick a line, then a direction and stop. Calls `onPick` with the finished selection.
struct LinePicker: View {
    let onPick: (Selection) -> Void

    @State private var lines: [Line] = []
    @State private var error: String?
    @State private var search = ""

    private var filtered: [Line] {
        guard !search.isEmpty else { return lines }
        return lines.filter { $0.id.localizedCaseInsensitiveContains(search) || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List(filtered) { line in
            NavigationLink(value: line) {
                HStack(spacing: 10) {
                    LineBadge(line: line.id, font: .system(.body, design: .rounded).weight(.heavy))
                        .frame(minWidth: 52, alignment: .leading)
                    Text(line.name)
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
            StopPicker(line: line, onPick: onPick)
        }
        .task {
            do { lines = try await TransitService.lines() } catch { self.error = error.localizedDescription }
        }
    }
}

struct StopPicker: View {
    let line: Line
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
                            destination: direction.destination, stopCode: stop.code, stopName: stop.name))
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
                directions = try await TransitService.directions(for: line)
                // Reopening the current line starts on the direction you already ride.
                let current = Selection.current
                if directionID == nil, current.lineID == line.id {
                    directionID = directions.first { $0.id == current.directionID }?.id
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

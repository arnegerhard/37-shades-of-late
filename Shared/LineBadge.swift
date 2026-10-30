import SwiftUI

/// Line number on a colored tag: Muni red (matching the app icon) unless given the line's own colors.
struct LineBadge: View {
    let line: String
    var font: Font = .system(.caption, design: .rounded).weight(.heavy)
    var color: Color = LineBadge.red
    var textColor: Color = .white
    /// A circle (a pill for a longer name, BART's "OAK"), as New York's subway, Muni Metro and Sound Transit have them; see
    /// `isRound`. `line` is what it says (see `short`), `spoken` what VoiceOver says, the whole name.
    var round = false
    var spoken: String? = nil

    static let red = Color(red: 0.75, green: 0.1, blue: 0.15)

    var body: some View {
        // VoiceOver says the whole name: "Yellow", not "Y".
        let text = Text(line).font(font).foregroundStyle(textColor).accessibilityLabel(spoken ?? line)
        if round {
            AtLeastSquare { text.padding(.horizontal, 4).padding(.vertical, 2) }
                .background(color, in: Capsule())
        } else {
            text
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(color, in: RoundedRectangle(cornerRadius: 4))
        }
    }

    /// Whether `ids` (combined, "KLM") are all lines whose badges are famously round: New York's
    /// subway (one letter or number, and the S shuttles; its buses all have more) and Muni Metro's
    /// J, K, L, M, N and T, and its historic streetcars, the E and F (not the "KBUS" or "FBUS"
    /// standing in for one), BART's lines (a "Y" for Yellow: their names would crowd out everything
    /// next to them, four at a stop), and Sound Transit's 1, 2 and T Lines and its Sounder trains, the N and
    /// S Lines (not King County Metro's RapidRide "A Line" and on, nor the "2 Line Shuttle" bus).
    /// As the site's (pages/s.html, src/card.ts).
    static func isRound(_ ids: [String], in city: City) -> Bool {
        !ids.isEmpty && ids.allSatisfy { id in
            switch city {
            case .nyc: id.count == 1 || id.hasPrefix("S ")
            case .sf: ["E", "F", "J", "K", "L", "M", "N", "T"].contains(id) || bartInitials[id] != nil
            case .seattle: ["1 Line", "2 Line", "T Line", "N Line", "S Line"].contains(id)
            case .boston: bostonSubway[id] != nil
            case .chicago: chicagoL[id] != nil
            }
        }
    }



    /// Boston's lines' colors: the subway's own (`bostonSubway`), and the rest by what they are: the
    /// Silver Line's buses silver, the other buses the MBTA's yellow, commuter rail purple, ferries teal.
    private static func bostonColor(of id: String) -> (hex: String, darkText: Bool)? {
        if let subway = bostonSubway[id] { return (subway.hex, false) }
        if id.hasPrefix("SL") { return ("#7C878E", false) }
        switch Line.known(id, in: .boston)?.mode {
        case "bus": return ("#FFC72C", true)
        case "rail": return ("#80276C", false)
        case "ferry": return ("#008EAA", false)
        default: return nil
        }
    }

    /// Chicago's 'L', in its colors, as initials (two letters where two lines share one: the Blue and
    /// Brown, the Purple and Pink).
    private static let chicagoL: [String: (short: String, hex: String)] = [
        "Red": ("R", "#C60C30"), "Blue": ("B", "#00A1DE"), "Brown": ("BR", "#62361B"), "Green": ("G", "#009B3A"),
        "Orange": ("O", "#F9461C"), "Purple": ("P", "#522398"), "Pink": ("PK", "#E27EA6"), "Yellow": ("Y", "#F9E300"),
    ]

    /// Boston's subway: its lines as the MBTA's signs say them, in their colors (the Green Line's
    /// branches by their letters; the Mattapan trolley's is the Red Line's).
    private static let bostonSubway: [String: (short: String, hex: String)] = [
        "Red": ("RL", "#DA291C"), "Orange": ("OL", "#ED8B00"), "Blue": ("BL", "#003DA5"), "Mattapan": ("M", "#DA291C"),
        "B": ("B", "#00843D"), "C": ("C", "#00843D"), "D": ("D", "#00843D"), "E": ("E", "#00843D"),
    ]

    /// `id` as its badge says it in `city`: BART's Yellow a "Y", Sound Transit's "1 Line" a "1",
    /// Boston's Red Line an "RL"; as it is otherwise. (Red, Orange and Blue are lines in both San
    /// Francisco and Boston, so it takes the city.)
    static func short(_ id: String, in city: City) -> String {
        guard isRound([id], in: city) else { return id }
        switch city {
        case .sf: return bartInitials[id] ?? id
        case .boston: return bostonSubway[id]?.short ?? id
        case .chicago: return chicagoL[id]?.short ?? id
        case .seattle: return id.hasSuffix(" Line") ? String(id.dropLast(5)) : id
        case .nyc: return id
        }
    }

    /// BART's lines, by their colors (the airport connector, "OAK", keeps its name in its circle).
    private static let bartInitials = ["Red": "R", "Orange": "O", "Yellow": "Y", "Green": "G", "Blue": "B", "OAK": "OAK"]
}

/// At least as wide as it is tall, so one character in a capsule makes a circle.
private struct AtLeastSquare: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(proposal) ?? .zero
        return CGSize(width: max(size.width, size.height), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: ProposedViewSize(bounds.size))
    }
}

extension LineBadge {
    /// The colors of the lines with badges of their own, as the agencies publish them (the line
    /// map's GTFS colors): "#RRGGBB", and whether the letters on it are black (New York's yellow
    /// lines). Those with round badges, BART's lines, and Seattle's RapidRide, in its dark red.
    static func color(of id: String, in city: City) -> (hex: String, darkText: Bool)? {
        switch city {
        case .nyc:
            switch id {
            case "1", "2", "3": ("#D82233", false)
            case "4", "5", "6": ("#009952", false)
            case "7": ("#9A38A1", false)
            case "A", "C", "E": ("#0062CF", false)
            case "B", "D", "F", "M": ("#EB6800", false)
            case "G": ("#799534", false)
            case "J", "Z": ("#8E5C33", false)
            case "N", "Q", "R", "W": ("#F6BC26", true)
            case "L": ("#7C858C", false)
            case _ where id.hasPrefix("S "): ("#7C858C", false)
            default: nil
            }
        case .sf:
            switch id {
            case "J": ("#A96614", false)
            case "K": ("#437C93", false)
            case "L": ("#942D83", false)
            case "M": ("#008547", false)
            case "N": ("#005B95", false)
            case "T": ("#BF2B45", false)
            // Muni's tan for the F; the E isn't in its data while it isn't running, so the grey its
            // route logo has.
            case "F": ("#B49A36", true)
            case "E": ("#666666", false)
            // BART's lines, by their colors.
            case "Red": ("#FF0000", false)
            case "Orange": ("#FF9933", true)
            case "Yellow": ("#FFFF33", true)
            case "Green": ("#339933", false)
            case "Blue": ("#0099CC", false)
            case "OAK": ("#B0BEC7", true)
            default: nil
            }
        case .seattle:
            switch id {
            case "1 Line": ("#28813F", false)
            case "2 Line": ("#007CAD", false)
            case "T Line": ("#F38B00", true)
            case "N Line", "S Line": ("#9AB6D3", true)
            case "A Line", "B Line", "C Line", "D Line", "E Line", "F Line", "G Line", "H Line": ("#9C182F", false)
            default: nil
            }
        case .boston:
            bostonColor(of: id)
        case .chicago:
            chicagoL[id].map { ($0.hex, $0.hex == "#F9E300") }
        }
    }
}

/// One badge of a choice's: some of its lines, in their color where they have a famous one.
struct BadgePart: Codable, Hashable {
    let label: String
    /// "#RRGGBB"; the app's red without one.
    var color: String? = nil
    var darkText = false
    /// Round, or a rectangle; as the whole choice's (`LineBadges.round`) when not set, as in Live
    /// Activities started before parts had their own.
    var round: Bool? = nil
}

extension Selection {
    /// Whether this choice's badge is round (see `LineBadge.isRound`).
    var roundBadge: Bool { LineBadge.isRound(lineIDs, in: city) }

    /// `lineLabel` with each line as its badge says it, for where there are no badges, only text (the
    /// Lock Screen widgets): "BGRY" for BART's Blue, Green, Red and Yellow, "12" for the 1 and 2 Lines.
    var shortLineLabel: String {
        let ids = lineIDs.map { LineBadge.short($0, in: city) }
        return ids.joined(separator: ids.allSatisfy { $0.count == 1 } ? "" : "·")
    }

    /// Its badges: one, in the app's red ("37", "5·21"), except for lines with badges of their own:
    /// subway, Muni Metro and Sound Transit lines come round and in their colors, a circle each, those
    /// sharing a color next to each other, as on New York's signs (the A, C and E in three blue circles,
    /// then the 2 in red), and RapidRide in its dark red. Any others with them share a red rectangle
    /// (the K, L and M in their circles, then a 24).
    var badgeParts: [BadgePart] {
        guard lineIDs.contains(where: { LineBadge.color(of: $0, in: city) != nil }) else { return [BadgePart(label: lineLabel)] }
        var groups: [(color: (hex: String, darkText: Bool)?, round: Bool, ids: [String])] = []
        for id in lineIDs {
            let color = LineBadge.color(of: id, in: city), round = LineBadge.isRound([id], in: city)
            if let i = groups.firstIndex(where: { $0.color?.hex == color?.hex && $0.round == round }) {
                groups[i].ids.append(id)
            } else {
                groups.append((color, round, [id]))
            }
        }
        return groups.flatMap { color, round, ids in
            round
                ? ids.map { BadgePart(label: LineBadge.short($0, in: city), color: color?.hex, darkText: color?.darkText ?? false, round: true) }
                : [BadgePart(label: ids.joined(separator: ids.allSatisfy { $0.count == 1 } ? "" : "·"),
                             color: color?.hex, darkText: color?.darkText ?? false, round: false)]
        }
    }
}

/// A choice's badges side by side (see `Selection.badgeParts`), or with `columns`, in rows of that
/// many, for where there's height to spare and not width (three or four BART lines at a stop, or
/// four buses, each its own badge then).
struct LineBadges: View {
    let parts: [BadgePart]
    var font: Font = .system(.caption, design: .rounded).weight(.heavy)
    var round = false
    var columns: Int? = nil

    var body: some View {
        // In rows, a rectangle for several lines ("2·120·121·124") is a badge per line, so it stacks too.
        let parts = columns == nil ? parts : parts.flatMap { part in
            let ids = part.label.split(separator: "·").map(String.init)
            return ids.count > 1 ? ids.map { BadgePart(label: $0, color: part.color, darkText: part.darkText, round: part.round) } : [part]
        }
        if let columns, parts.count > columns {
            Grid(alignment: .leading, horizontalSpacing: 3, verticalSpacing: 3) {
                ForEach(Array(stride(from: 0, to: parts.count, by: columns)), id: \.self) { start in
                    GridRow {
                        ForEach(parts[start..<min(start + columns, parts.count)], id: \.self, content: badge)
                    }
                }
            }
        } else {
            HStack(spacing: 3) {
                ForEach(parts, id: \.self, content: badge)
            }
        }
    }

    private func badge(_ part: BadgePart) -> some View {
        LineBadge(line: part.label, font: font, color: Color(hex: part.color) ?? LineBadge.red,
                  textColor: part.darkText ? .black : .white, round: part.round ?? round)
    }
}

extension Color {
    /// A "#RRGGBB" color, as the proxy sends official GTFS route colors.
    init?(hex: String?) {
        guard let hex, hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

extension LineBadge {
    /// One line's badge, as on the line map: round and in its color where it has one (see
    /// `isRound`, `color`), else a rectangle in its color or the app's red.
    static func single(_ id: String, in city: City, font: Font) -> LineBadge {
        let color = Self.color(of: id, in: city)
        return LineBadge(line: short(id, in: city), font: font, color: Color(hex: color?.hex) ?? red,
                         textColor: color?.darkText == true ? .black : .white, round: isRound([id], in: city), spoken: id)
    }
}

/// A stop's next few waits, as `Departure.waits` words them, but for combined lines with each one's
/// badge in front instead of its name: [A] 2 · [C] 5 · [E] 6 min. A single line's are just minutes.
/// The minutes take the font and color around it; the badges, `badgeFont`, a size or so smaller.
struct WaitsLabel: View {
    let departures: [Departure]
    let date: Date
    let count: Int
    let selection: Selection
    var unit = true
    var badgeFont: Font = .system(.caption2, design: .rounded).weight(.heavy)

    var body: some View {
        let next = Array(departures.filter { $0.time > date.addingTimeInterval(-30) }.prefix(count))
        if selection.isMultiLine {
            HStack(spacing: 3) {
                ForEach(Array(next.enumerated()), id: \.offset) { i, departure in
                    if i > 0 { Text("·").padding(.horizontal, 1) }
                    if let line = departure.line {
                        LineBadge.single(line, in: selection.city, font: badgeFont).fixedSize()
                    }
                    Text(wait(departure, last: i == next.count - 1))
                }
            }
        } else {
            Text(Departure.waits(next, from: date, count: count, unit: unit) ?? "")
        }
    }

    /// "4", "now", or "16 min" for the last one (but not "now min").
    private func wait(_ departure: Departure, last: Bool) -> String {
        let minutes = max(0, Int(departure.time.timeIntervalSince(date) / 60))
        return minutes == 0 ? "now" : "\(minutes)" + (unit && last ? " min" : "")
    }
}

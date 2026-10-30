import SwiftUI

/// Line number on a colored tag: Muni red (matching the app icon) unless given the line's own colors.
struct LineBadge: View {
    let line: String
    var font: Font = .system(.caption, design: .rounded).weight(.heavy)
    var color: Color = LineBadge.red
    var textColor: Color = .white
    /// A circle (a pill for "KLM"), as New York's subway and Muni Metro have them; see `isRound`.
    var round = false

    static let red = Color(red: 0.75, green: 0.1, blue: 0.15)

    var body: some View {
        let text = Text(line).font(font).foregroundStyle(textColor)
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
    /// J, K, L, M, N and T (not the F, a streetcar on the street, nor the "KBUS" standing in for one).
    /// As the site's (pages/s.html, src/card.ts).
    static func isRound(_ ids: [String], in city: City) -> Bool {
        !ids.isEmpty && ids.allSatisfy { id in
            switch city {
            case .nyc: id.count == 1 || id.hasPrefix("S ")
            case .sf: ["J", "K", "L", "M", "N", "T"].contains(id)
            case .seattle: false
            }
        }
    }
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
    /// The colors of the lines with round badges, as the agencies publish them (the line map's GTFS
    /// colors): "#RRGGBB", and whether the letters on it are black (New York's yellow lines).
    static func roundColor(of id: String, in city: City) -> (hex: String, darkText: Bool)? {
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
            default: nil
            }
        case .seattle: nil
        }
    }
}

/// One badge of a choice's: some of its lines, in their color where they have a famous one.
struct BadgePart: Codable, Hashable {
    let label: String
    /// "#RRGGBB"; the app's red without one.
    var color: String? = nil
    var darkText = false
}

extension Selection {
    /// Whether this choice's badge is round (see `LineBadge.isRound`).
    var roundBadge: Bool { LineBadge.isRound(lineIDs, in: city) }

    /// Its badges: one, in the app's red ("37", "5·21"), except for subway and Muni Metro lines,
    /// which come in their colors, those sharing one together (the A, C and E as a blue "ACE",
    /// with the 2 next to it in red).
    var badgeParts: [BadgePart] {
        guard roundBadge else { return [BadgePart(label: lineLabel)] }
        var groups: [(color: (hex: String, darkText: Bool)?, ids: [String])] = []
        for id in lineIDs {
            let color = LineBadge.roundColor(of: id, in: city)
            if let i = groups.firstIndex(where: { $0.color?.hex == color?.hex }) { groups[i].ids.append(id) } else { groups.append((color, [id])) }
        }
        return groups.map { color, ids in
            BadgePart(label: ids.joined(separator: ids.allSatisfy { $0.count == 1 } ? "" : "·"),
                      color: color?.hex, darkText: color?.darkText ?? false)
        }
    }
}

/// A choice's badges side by side (see `Selection.badgeParts`).
struct LineBadges: View {
    let parts: [BadgePart]
    var font: Font = .system(.caption, design: .rounded).weight(.heavy)
    var round = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(parts, id: \.self) { part in
                LineBadge(line: part.label, font: font, color: Color(hex: part.color) ?? LineBadge.red,
                          textColor: part.darkText ? .black : .white, round: round)
            }
        }
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
    /// `isRound`, `roundColor`), else a rectangle in the app's red.
    static func single(_ id: String, in city: City, font: Font) -> LineBadge {
        let color = roundColor(of: id, in: city)
        return LineBadge(line: id, font: font, color: Color(hex: color?.hex) ?? red,
                         textColor: color?.darkText == true ? .black : .white, round: isRound([id], in: city))
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

import SwiftUI

/// Line number on a colored tag: Muni red (matching the app icon) unless given the line's own colors.
struct LineBadge: View {
    let line: String
    var font: Font = .system(.caption, design: .rounded).weight(.heavy)
    var color: Color = LineBadge.red
    var textColor: Color = .white

    static let red = Color(red: 0.75, green: 0.1, blue: 0.15)

    var body: some View {
        Text(line)
            .font(font)
            .foregroundStyle(textColor)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color, in: RoundedRectangle(cornerRadius: 4))
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

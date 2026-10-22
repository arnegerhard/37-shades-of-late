import SwiftUI

/// White line number on Muni red, matching the app icon.
struct LineBadge: View {
    let line: String
    var font: Font = .system(.caption, design: .rounded).weight(.heavy)

    static let red = Color(red: 0.75, green: 0.1, blue: 0.15)

    var body: some View {
        Text(line)
            .font(font)
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Self.red, in: RoundedRectangle(cornerRadius: 4))
    }
}

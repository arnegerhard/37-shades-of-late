import CoreImage.CIFilterBuiltins
import SwiftUI

// Sharing a stop with a friend: a link to 37shadesoflate.com/s that shows the stop's live times on the web
// (or opens it in the app, where it can be added), as a card with the wait and its quip, or as a QR code
// with the 37 in the middle for showing in person.

extension Selection {
    /// https://37shadesoflate.com/s?c=sf&l=37&s=13254&d=IB — city, line, stop and direction.
    var shareURL: URL {
        var components = URLComponents(string: "https://37shadesoflate.com/s")!
        components.queryItems = [
            URLQueryItem(name: "c", value: city.rawValue),
            URLQueryItem(name: "l", value: lineID),
            URLQueryItem(name: "s", value: stopCode),
            URLQueryItem(name: "d", value: directionID),
        ]
        return components.url!
    }

    /// The stop a shared link points to, with its names looked up like the line picker does, or nil if
    /// it isn't one (or the line or stop no longer exists).
    static func shared(by url: URL) async -> Selection? {
        guard url.host()?.hasSuffix("37shadesoflate.com") == true, url.path() == "/s",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard let city = value("c").flatMap(City.init(rawValue:)), let lineID = value("l"), let stopCode = value("s") else { return nil }
        let line = TransitService.cachedLines(in: city).first { $0.id == lineID } ?? Line(id: lineID, name: "", mode: "bus")
        guard let directions = try? await TransitService.directions(for: line, in: city),
              let direction = directions.first(where: { $0.id == value("d") && $0.stops.contains { $0.code == stopCode } })
                ?? directions.first(where: { $0.stops.contains { $0.code == stopCode } }),
              let stop = direction.stops.first(where: { $0.code == stopCode })
        else { return nil }
        return Selection(lineID: line.id, lineName: line.name, directionID: direction.id, destination: direction.destination,
                         stopCode: stop.code, stopName: stop.name, city: city)
    }
}

/// What the share button on the live map opens: the card to send, or the QR code to show.
struct ShareSheet: View {
    let selection: Selection
    let departures: [Departure]

    @Environment(\.dismiss) private var dismiss
    @State private var showingQR = false
    @State private var card: UIImage?
    @State private var sending = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Picker("Share as", selection: $showingQR) {
                    Text("Card").tag(false)
                    Text("QR code").tag(true)
                }
                .pickerStyle(.segmented)

                if showingQR {
                    QRCodeView(url: selection.shareURL)
                        .frame(maxWidth: 300)
                        .frame(maxHeight: .infinity)
                    Text("Your friend points their camera here and gets this stop's live times, or opens it in the app.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    ShareCard(selection: selection, departures: departures, now: .now)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
                        .frame(maxHeight: .infinity)
                }

                Button { sending = true } label: {
                    Label(showingQR ? "Send the link" : "Send to a friend", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(LineBadge.red)
                .disabled(card == nil)
                // UIKit's share sheet, handed the finished picture and the text up front. (SwiftUI's
                // ShareLink with an Image renders it when the receiving app asks, on the main thread,
                // which hung the app when sending to Messages.)
                .background {
                    ActivitySheet(isPresented: $sending, items: [card as Any?, message].compactMap { $0 })
                }
            }
            .padding(24)
            .navigationTitle("Share the suffering")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task {
            // The card as a picture, sent with the link; at 3x it's sharp in Messages and Stories.
            let renderer = ImageRenderer(content: ShareCard(selection: selection, departures: departures, now: .now))
            renderer.scale = 3
            card = renderer.uiImage
        }
    }

    /// What goes with the picture: the wait, its quip and the link to the stop.
    private var message: String {
        let next = departures.first { $0.time > .now.addingTimeInterval(-30) }
        let wait = Departure.waits(departures, from: .now, count: 1, lines: selection.isMultiLine).map { ": \($0)" } ?? ""
        let quip = next.map { Quip.forWait(until: $0.time, line: $0.line ?? selection.lineLabel) } ?? Quip.noPrediction(line: selection.lineLabel)
        return "The \(selection.lineLabel) at \(selection.stopName)\(wait). “\(quip)” \(selection.shareURL.absoluteString)"
    }
}

/// Presents UIKit's share sheet with `items` while `isPresented` is true.
private struct ActivitySheet: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let items: [Any]

    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        guard isPresented, host.presentedViewController == nil else { return }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, _, _, _ in isPresented = false }
        sheet.popoverPresentationController?.sourceView = host.view
        DispatchQueue.main.async { host.present(sheet, animated: true) }
    }
}

/// The picture that gets sent: the ride, the wait, its quip, and where it came from.
struct ShareCard: View {
    let selection: Selection
    let departures: [Departure]
    let now: Date

    private var upcoming: [Departure] { departures.filter { $0.time > now.addingTimeInterval(-30) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                LineBadge(line: selection.lineLabel, font: .system(size: 26, weight: .heavy, design: .rounded))
                    .fixedSize()
                VStack(alignment: .leading, spacing: 2) {
                    Text("To \(selection.destination)").font(.system(size: 19, weight: .bold, design: .rounded))
                    Text(selection.stopName).font(.system(size: 15)).foregroundStyle(.white.opacity(0.6))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 18)
            if let next = upcoming.first {
                Text(Departure.waits([next], from: now, count: 1, lines: selection.isMultiLine) ?? "")
                    .font(.system(size: 76, weight: .heavy, design: .rounded))
                    .foregroundStyle(next.isLive ? .green : .white.opacity(0.6))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                if let later = Departure.waits(Array(upcoming.dropFirst()), from: now, count: 2, unit: false, lines: selection.isMultiLine) {
                    Text("then \(later)").font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.6))
                }
            } else {
                Text("??").font(.system(size: 76, weight: .heavy, design: .rounded)).foregroundStyle(.white.opacity(0.6))
            }
            Text("“\(upcoming.first.map { Quip.forWait(until: $0.time, from: now, line: $0.line ?? selection.lineLabel) } ?? Quip.noPrediction(line: selection.lineLabel))”")
                .font(.system(size: 21, weight: .medium))
                .italic()
                .padding(.top, 14)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 22)
            HStack(spacing: 8) {
                Text("37").font(.system(size: 13, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(LineBadge.red, in: RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 1) {
                    Text("37 Shades of Late").font(.system(size: 15, weight: .heavy, design: .rounded))
                    Text("37shadesoflate.com").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(26)
        .frame(width: 360, height: 400, alignment: .topLeading)
        .background(
            LinearGradient(colors: [Color(red: 0.08, green: 0.09, blue: 0.17), Color(red: 0.2, green: 0.08, blue: 0.16)],
                           startPoint: .top, endPoint: .bottom)
        )
        .environment(\.colorScheme, .dark)
    }
}

/// A QR code for `url`, with the red 37 in the middle. It uses the highest error correction (30%), so the
/// covered middle (about 5% of the code) still scans.
struct QRCodeView: View {
    let url: URL

    var body: some View {
        if let image = Self.image(for: url) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .overlay {
                    GeometryReader { geometry in
                        let side = geometry.size.width * 0.22
                        Text("37")
                            .font(.system(size: side * 0.48, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: side, height: side)
                            .background(LineBadge.red, in: RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
                            // A white rim, so the badge doesn't run into the modules around it.
                            .padding(side * 0.06)
                            .background(.white, in: RoundedRectangle(cornerRadius: side * 0.26, style: .continuous))
                            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    }
                }
                .padding(18)
                .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .accessibilityLabel("QR code for this stop")
        }
    }

    static func image(for url: URL) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "H"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

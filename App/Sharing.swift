import CoreImage.CIFilterBuiltins
import LinkPresentation
import SwiftUI

// Sharing a stop with a friend: a link to 37shadesoflate.com/s that shows the stop's live times on the web
// (or opens it in the app, where it can be added), as a card with the wait and its quip, or as a QR code
// with the 37 in the middle for showing in person.

extension Selection {
    /// https://37shadesoflate.com/s?c=sf&l=37&s=13254&d=IB&f=k3x9p2 — city, line, stop and direction,
    /// and who shared it (this install's share code, see AppGroup.shareCode). Lines combined with it come
    /// along as lists, as the proxy takes them: l=K,L,M&d=IB,IB,IB (and a stop per line, when one is
    /// caught at a nearby stop).
    var shareURL: URL { shareURL(qr: false) }

    /// The link, as a QR code shows it: q=1, to tell scans in person from links sent.
    func shareURL(qr: Bool) -> URL {
        var components = URLComponents(url: stopURL, resolvingAgainstBaseURL: false)!
        components.queryItems! += [URLQueryItem(name: "f", value: AppGroup.shareCode)] + (qr ? [URLQueryItem(name: "q", value: "1")] : [])
        return components.url!
    }

    /// The stop alone, nobody's: what the card is drawn for, so cards are the same for everyone.
    private var stopURL: URL {
        var components = URLComponents(string: "https://37shadesoflate.com/s")!
        let query = Dictionary(uniqueKeysWithValues: TransitService.departuresQuery(for: self).map { ($0.key, $0.value) })
        components.queryItems = [
            URLQueryItem(name: "c", value: city.rawValue),
            URLQueryItem(name: "l", value: query["line"]),
            URLQueryItem(name: "s", value: query["stop"]),
            URLQueryItem(name: "d", value: query["direction"]),
        ]
        return components.url!
    }

    /// The card the website draws for `shareURL`, with the wait and a map of the buses on their way:
    /// what WhatsApp and the like show for the link, and so what the app shows and sends too.
    var shareCardURL: URL {
        var components = URLComponents(url: stopURL, resolvingAgainstBaseURL: false)!
        components.path = "/s/card.png"
        return components.url!
    }

    /// "37", or "K, L or M" for combined lines.
    var spokenLines: String {
        let ids = lineIDs
        return ids.count == 1 ? ids[0] : ids.dropLast().joined(separator: ", ") + " or " + ids.last!
    }

    /// Who shared a link, as it says: their share code, "qr" if it came from a QR code, and "new" if this
    /// install is (see AppGroup.isNew): "k3x9p2 qr new". Nil for links from before there were codes.
    static func sharer(of url: URL) -> String? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let code = items.first(where: { $0.name == "f" })?.value, AppGroup.isShareCode(code) else { return nil }
        let qr = items.contains { $0.name == "q" && $0.value == "1" }
        return [code, qr ? "qr" : nil, AppGroup.isNew ? "new" : nil].compactMap { $0 }.joined(separator: " ")
    }

    /// The stop a shared link points to, with its names looked up like the line picker does, or nil if
    /// it isn't one (or the line or stop no longer exists).
    static func shared(by url: URL) async -> Selection? {
        guard url.host()?.hasSuffix("37shadesoflate.com") == true, url.path() == "/s",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let value = { (name: String) in items.first { $0.name == name }?.value }
        let list = { (name: String) in (value(name) ?? "").split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        let lineIDs = list("l"), directionIDs = list("d"), stopCodes = list("s")
        guard let city = value("c").flatMap(City.init(rawValue:)), let lineID = lineIDs.first, !lineID.isEmpty,
              let stopCode = stopCodes.first, !stopCode.isEmpty else { return nil }
        // The lines combined with the first one, each with its direction, and its own stop if that's another.
        let also = lineIDs.indices.dropFirst().map { i in
            OtherLine(lineID: lineIDs[i], directionID: directionIDs.indices.contains(i) ? directionIDs[i] : "",
                      stopCode: stopCodes.indices.contains(i) && stopCodes[i] != stopCode ? stopCodes[i] : nil)
        }
        let line = TransitService.cachedLines(in: city).first { $0.id == lineID } ?? Line(id: lineID, name: "", mode: "bus")
        guard let directions = try? await TransitService.directions(for: line, in: city),
              let direction = directions.first(where: { $0.id == directionIDs.first && $0.stops.contains { $0.code == stopCode } })
                ?? directions.first(where: { $0.stops.contains { $0.code == stopCode } }),
              let stop = direction.stops.first(where: { $0.code == stopCode })
        else { return nil }
        return Selection(lineID: line.id, lineName: line.name, directionID: direction.id, destination: direction.destination,
                         stopCode: stop.code, stopName: stop.name, city: city, also: also)
    }
}

/// What the home map's share button opens: the card to send, or the QR code to show.
struct ShareSheet: View {
    let selection: Selection
    let departures: [Departure]
    /// Where it was opened, for Journey (see `Journey.from`).
    var from = "map"

    @Environment(\.dismiss) private var dismiss
    @State private var showingQR = false
    @State private var card: UIImage?
    /// The website's card, with the map, once it's here; the app's own card until then (or without a connection).
    @State private var webCard: UIImage?
    /// When the website's card was asked for, while it's on its way.
    @State private var cardAsked: Date?
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
                    QRCodeView(url: selection.shareURL(qr: true))
                        .frame(maxWidth: 300)
                        .frame(maxHeight: .infinity)
                    Text("Your friend points their camera here and gets this stop's live times, or opens it in the app.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    // Exactly what they get: the card, map and all, on a link that opens the stop live.
                    VStack(spacing: 14) {
                        Group {
                            if let webCard {
                                Image(uiImage: webCard)
                                    .resizable()
                                    .scaledToFit()
                                    .transition(.opacity)
                            } else {
                                ShareCard(selection: selection, departures: departures, now: .now)
                            }
                        }
                        // While the map's version is on its way, a bar along the bottom, like the home map's.
                        .overlay(alignment: .bottom) {
                            if let cardAsked {
                                CardLoadingBar(since: cardAsked).transition(.opacity)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
                        Text("They get this card, and a tap opens the stop live: the minutes and the map, in the app or on the web.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxHeight: .infinity)
                }

                Button { Journey.shared.tap("share.send", "\(showingQR ? "qr" : "card"), \(Journey.from(from))"); sending = true } label: {
                    Label(showingQR ? "Send the link" : "Send to a friend", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(LineBadge.red)
                .disabled(card == nil)
                // UIKit's share sheet with just the stop's link, which opens the stop in the app or its
                // live times on the web, and the card as its preview: Messages sends them as one bubble,
                // the card with the stop's name under it. No text: the card says it all. (SwiftUI's
                // ShareLink with an Image renders it when the receiving app asks, on the main thread,
                // which hung the app when sending to Messages.)
                .background {
                    ActivitySheet(isPresented: $sending, items: [StopLink(selection: selection, card: showingQR ? nil : webCard ?? card)])
                }
            }
            .padding(24)
            .navigationTitle("Share the suffering")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { Journey.shared.tap("share.done", Journey.from(from)); dismiss() } }
            }
        }
        .journeyScreen("share", Journey.from(from))
        .task {
            // The app's own card first, so there's something to send right away; at 3x it's sharp.
            let renderer = ImageRenderer(content: ShareCard(selection: selection, departures: departures, now: .now))
            renderer.scale = 3
            card = renderer.uiImage
            // Then the website's, with the map, as the link's preview shows it everywhere else.
            cardAsked = .now
            defer { withAnimation(.easeOut(duration: 0.3)) { cardAsked = nil } }
            if let (data, response) = try? await URLSession.shared.data(from: selection.shareCardURL),
               (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data) {
                withAnimation(.easeInOut(duration: 0.3)) { webCard = image }
            }
        }
    }
}

/// The home map's refresh bar, filling instead of emptying while the website draws its card: there's
/// no knowing how long that takes (a few seconds, with the map), so it slows as it goes, never quite full.
private struct CardLoadingBar: View {
    let since: Date

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1)) { context in
            let progress = 0.92 * (1 - exp(-context.date.timeIntervalSince(since) / 2.5))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.black.opacity(0.12))
                    Rectangle()
                        .fill(LineBadge.red)
                        .frame(width: geometry.size.width * progress)
                }
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

/// A stop's link for the share sheet, with its title ("The 37 at 14th St & Church St") and the card as
/// its picture, so the sheet and Messages show them without fetching the page.
private final class StopLink: NSObject, UIActivityItemSource {
    let selection: Selection
    /// The link's picture: big in Messages, small in the share sheet.
    let card: UIImage?

    init(selection: Selection, card: UIImage?) {
        self.selection = selection
        self.card = card
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { selection.shareURL }

    func activityViewController(_ controller: UIActivityViewController, itemForActivityType type: UIActivity.ActivityType?) -> Any? {
        selection.shareURL
    }

    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.originalURL = selection.shareURL
        metadata.url = selection.shareURL
        metadata.title = "The \(selection.spokenLines) at \(selection.stopName)"
        if let card {
            metadata.imageProvider = NSItemProvider(object: card)
            metadata.iconProvider = NSItemProvider(object: card)
        }
        return metadata
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
                LineBadges(parts: selection.badgeParts, font: .system(size: 26, weight: .heavy, design: .rounded), round: selection.roundBadge)
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
                WaitsLabel(departures: [next], date: now, count: 1, selection: selection,
                           badgeFont: .system(size: 40, weight: .heavy, design: .rounded))
                    .font(.system(size: 76, weight: .heavy, design: .rounded))
                    .foregroundStyle(next.isLive ? .green : .white.opacity(0.6))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                if upcoming.count > 1 {
                    HStack(spacing: 4) {
                        Text("then")
                        WaitsLabel(departures: Array(upcoming.dropFirst()), date: now, count: 2, selection: selection, unit: false,
                                   badgeFont: .system(size: 12, weight: .heavy, design: .rounded))
                    }
                    .font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.6))
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

import AVFoundation
import SwiftUI
import SwiftyTube

/// A card the uploader placed over the last seconds of the video: another video, a playlist or the channel.
struct EndScreenElement: Identifiable, Equatable {
    enum Target: Equatable {
        case video(String)
        case channel(String)
    }

    let id: Int
    let title: String
    let image: String?
    let target: Target
    let isRound: Bool
    /// Where it sits, as fractions of the picture's width and height.
    let left, top, width, aspectRatio: Double
    let start, end: Double

    /// Websites and merchandise lead out of the app, so only videos, playlists and channels are kept.
    static func elements(in playerJSON: [String: Any]) -> [EndScreenElement] {
        let list = JSON.first("elements", in: playerJSON["endscreen"]) as? [[String: Any]] ?? []
        return list.enumerated().compactMap { index, item in
            guard let card = item["endscreenElementRenderer"] as? [String: Any],
                  let style = card["style"] as? String,
                  let start = seconds(card["startMs"]), let end = seconds(card["endMs"]),
                  let left = card["left"] as? Double, let top = card["top"] as? Double,
                  let width = card["width"] as? Double else { return nil }
            let target: Target
            switch style {
            case "VIDEO", "PLAYLIST":
                guard let id = JSON.string("videoId", in: card["endpoint"]) else { return nil }
                target = .video(id)
            case "CHANNEL", "SUBSCRIBE":
                guard let id = JSON.string("browseId", in: card["endpoint"]) else { return nil }
                target = .channel(id)
            default:
                return nil
            }
            return EndScreenElement(
                id: index,
                title: JSON.text(card["title"]) ?? "",
                image: JSON.lastThumbnail(card["image"]),
                target: target,
                isRound: style == "CHANNEL" || style == "SUBSCRIBE",
                left: left, top: top, width: width,
                aspectRatio: card["aspectRatio"] as? Double ?? 16 / 9,
                start: start, end: end
            )
        }
    }

    /// YouTube sends milliseconds as text.
    private static func seconds(_ value: Any?) -> Double? {
        let ms = (value as? String).flatMap(Double.init) ?? (value as? NSNumber)?.doubleValue
        return ms.map { $0 / 1000 }
    }

    /// The WEB client's answer has the end screen; the clients that play the video often leave it out.
    static func load(videoId: String) async -> [EndScreenElement] {
        guard let json = try? await YouTubeAPI.post("player", body: ["videoId": videoId]) else { return [] }
        return elements(in: json)
    }

    static func selfCheck() {
        let json: [String: Any] = ["endscreen": ["endscreenRenderer": ["elements": [
            ["endscreenElementRenderer": ["style": "VIDEO", "startMs": "100000", "endMs": "120000", "left": 0.1, "top": 0.2, "width": 0.3,
                                          "aspectRatio": 1.7, "title": ["simpleText": "Next"], "endpoint": ["watchEndpoint": ["videoId": "abc"]]]],
            ["endscreenElementRenderer": ["style": "CHANNEL", "startMs": "100000", "endMs": "120000", "left": 0.6, "top": 0.2, "width": 0.15,
                                          "aspectRatio": 1.0, "endpoint": ["browseEndpoint": ["browseId": "UC1"]]]],
            ["endscreenElementRenderer": ["style": "WEBSITE", "startMs": "100000", "endMs": "120000", "left": 0.6, "top": 0.6, "width": 0.2]],
        ]]]]
        let found = elements(in: json)
        assert(found.count == 2)
        assert(found[0].target == .video("abc") && found[0].start == 100 && !found[0].isRound)
        assert(found[1].target == .channel("UC1") && found[1].isRound)
    }
}

/// The end screen's cards, where the uploader put them on the picture.
struct EndScreenOverlay: View {
    @ObservedObject var clock: PlayerClock
    let elements: [EndScreenElement]
    @Environment(Router.self) private var router

    private var shown: [EndScreenElement] {
        elements.filter { $0.start <= clock.time && clock.time < $0.end }
    }

    var body: some View {
        GeometryReader { proxy in
            // ponytail: assumes a 16:9 picture; a 4:3 video in full screen puts the cards a little off.
            let picture = AVMakeRect(aspectRatio: CGSize(width: 16, height: 9), insideRect: CGRect(origin: .zero, size: proxy.size))
            ForEach(shown) { element in
                let width = picture.width * element.width
                Button { open(element) } label: {
                    card(element)
                        .frame(width: width, height: width / element.aspectRatio)
                }
                .buttonStyle(ZoomPressStyle())
                .accessibilityLabel(element.title)
                .position(x: picture.minX + picture.width * element.left + width / 2,
                          y: picture.minY + picture.height * element.top + width / element.aspectRatio / 2)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: shown)
    }

    private func card(_ element: EndScreenElement) -> some View {
        Color.black
            .overlay { CachedImage(url: element.image) }
            .overlay(alignment: .bottomLeading) {
                if !element.isRound, !element.title.isEmpty {
                    Text(element.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.85), radius: 1, y: 1)
                        .shadow(color: .black.opacity(0.55), radius: 5)
                        .padding(4)
                }
            }
            .clipShape(element.isRound ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: Layout.cardSpacing)))
            .overlay {
                (element.isRound ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: Layout.cardSpacing)))
                    .stroke(.white.opacity(0.7), lineWidth: 1)
            }
    }

    private func open(_ element: EndScreenElement) {
        switch element.target {
        case .video(let id):
            router.openVideo(YouTubeVideo(videoId: id, title: element.title, thumbnailURL: element.image))
        case .channel(let id):
            router.openChannelPage(id)
        }
    }
}

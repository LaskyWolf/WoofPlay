import Combine
import Foundation
import Network

/// Takes Twitch's ads out of a media playlist. Twitch stitches ads into the stream as segments
/// whose `#EXTINF` title isn't "live", announced by a `twitch-stitched-ad` date range.
struct TwitchAdFilter {
    struct Result {
        let playlist: String
        let segments: Int
        /// Set while the newest segment is an ad. `adEnds` is nil when Twitch gave no end time.
        let isAd: Bool
        let adEnds: Date?
    }

    /// Dropping segments shifts the rest, so each kept segment gets its own number that never changes.
    private var numbers: [String: Int] = [:]
    private var nextNumber = 0
    /// The last live init section. An ad has its own, which mpv must never get.
    private var liveMap: String?

    mutating func clean(_ playlist: String) -> Result {
        var targetDuration = "6"
        var isFinished = false
        var adEnds: Date?
        var pending: [String] = []
        var kept: [(map: String?, info: String, uri: String)] = []
        var newestIsAd = false

        for line in playlist.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                targetDuration = String(line.dropFirst("#EXT-X-TARGETDURATION:".count))
            } else if line == "#EXT-X-ENDLIST" {
                isFinished = true
            } else if line.hasPrefix("#EXT-X-DATERANGE:"), line.contains("twitch-stitched-ad"),
                      let start = Twitch.attribute("START-DATE", in: line).flatMap(Self.date),
                      let duration = Twitch.attribute("DURATION", in: line).flatMap(Double.init) {
                adEnds = max(adEnds ?? .distantPast, start.addingTimeInterval(duration))
            } else if line.hasPrefix("#") {
                pending.append(line)
            } else if !line.isEmpty {
                let info = pending.last { $0.hasPrefix("#EXTINF:") } ?? "#EXTINF:2.000,live"
                let map = pending.last { $0.hasPrefix("#EXT-X-MAP:") }
                newestIsAd = !info.hasSuffix(",live")
                if !newestIsAd {
                    kept.append((map, info, line))
                }
                pending = []
            }
        }

        var lines = ["#EXTM3U", "#EXT-X-VERSION:6", "#EXT-X-TARGETDURATION:\(targetDuration)"]
        var known: [String: Int] = [:]
        var emittedMap: String?
        for (index, segment) in kept.enumerated() {
            let number: Int
            if let old = numbers[segment.uri] {
                number = old
            } else {
                number = nextNumber
                nextNumber += 1
            }
            known[segment.uri] = number
            if index == 0 { lines.append("#EXT-X-MEDIA-SEQUENCE:\(number)") }
            if let map = segment.map { liveMap = map }
            if let liveMap, liveMap != emittedMap {
                lines.append(liveMap)
                emittedMap = liveMap
            }
            lines += [segment.info, segment.uri]
        }
        numbers = known
        if kept.isEmpty { lines.append("#EXT-X-MEDIA-SEQUENCE:\(nextNumber)") }
        if isFinished { lines.append("#EXT-X-ENDLIST") }
        return Result(playlist: lines.joined(separator: "\n") + "\n", segments: kept.count, isAd: newestIsAd, adEnds: newestIsAd ? adEnds : nil)
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    static func selfCheck() {
        var filter = TwitchAdFilter()
        let ad = """
        #EXTM3U
        #EXT-X-TARGETDURATION:5
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-DATERANGE:ID="stitched-ad-1",CLASS="twitch-stitched-ad",START-DATE="2026-11-15T10:05:06.683Z",DURATION=30.235,X-TV-TWITCH-AD-URL="https://www.twitch.tv"
        #EXT-X-DISCONTINUITY
        #EXT-X-MAP:URI="https://cdn/ad-init.mp4"
        #EXTINF:2.000,Amazon|123
        https://cdn/ad1.mp4
        """
        let first = filter.clean(ad)
        assert(first.segments == 0 && first.isAd)
        assert(abs((first.adEnds ?? .distantPast).timeIntervalSince(date("2026-11-15T10:05:36.918Z")!)) < 0.01)
        assert(!first.playlist.contains("ad-init") && !first.playlist.contains("ad1"))

        let mixed = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:900
        #EXT-X-MAP:URI="https://cdn/live-init.mp4"
        #EXTINF:2.000,live
        https://cdn/live1.mp4
        #EXT-X-DISCONTINUITY
        #EXT-X-MAP:URI="https://cdn/ad-init.mp4"
        #EXTINF:2.000,Amazon|123
        https://cdn/ad1.mp4
        #EXT-X-DISCONTINUITY
        #EXT-X-MAP:URI="https://cdn/live-init.mp4"
        #EXTINF:2.000,live
        https://cdn/live2.mp4
        """
        let second = filter.clean(mixed)
        assert(second.segments == 2 && !second.isAd)
        assert(second.playlist.contains("#EXT-X-MEDIA-SEQUENCE:0\n"))
        assert(second.playlist.components(separatedBy: "live-init").count == 2, "one init section")
        assert(!second.playlist.contains("ad1") && !second.playlist.contains("DISCONTINUITY"))

        // The window moved on by one: live2 keeps its number, so mpv neither repeats nor skips it.
        let third = filter.clean("""
        #EXTM3U
        #EXTINF:2.000,live
        https://cdn/live2.mp4
        #EXTINF:2.000,live
        https://cdn/live3.mp4
        """)
        assert(third.playlist.contains("#EXT-X-MEDIA-SEQUENCE:1\n"))
        assert(third.playlist.contains("live-init"), "keeps the init section once it scrolled away")
    }
}

/// Serves Twitch's media playlist to mpv from 127.0.0.1 with the ads taken out.
/// mpv asks again every few seconds, and each time the playlist comes fresh from Twitch.
/// Video segments still come straight from Twitch's servers.
@MainActor
final class TwitchStream: ObservableObject {
    @Published private(set) var isAd = false
    @Published private(set) var adEnds: Date?

    private let upstream: URL
    private let listener: NWListener
    private var filter = TwitchAdFilter()
    private static let waitForLive = Duration.seconds(2)

    init(upstream: URL) throws {
        self.upstream = upstream
        let parameters = NWParameters.tcp
        // Only this phone can connect, never another device on the Wi-Fi.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Starts the server and returns the address for mpv once the playlist has something that isn't an ad.
    func start() async throws -> String {
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.serve(connection) }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            // Cleared after the first answer, so the continuation resumes once.
            listener.stateUpdateHandler = { [weak listener = self.listener] state in
                switch state {
                case .ready:
                    listener?.stateUpdateHandler = nil
                    continuation.resume(returning: listener?.port?.rawValue ?? 0)
                case .failed(let error):
                    listener?.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    listener?.stateUpdateHandler = nil
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.start(queue: .main)
        }
        // mpv gives up on a playlist with nothing in it, so a pre-roll is waited out here.
        while true {
            let playlist = try await fetch()
            guard playlist.status == 200 else { throw TwitchError("Twitch didn't send the stream (error \(playlist.status)).") }
            if playlist.segments > 0 { break }
            try await Task.sleep(for: Self.waitForLive)
        }
        return "http://127.0.0.1:\(port)/live.m3u8"
    }

    func stop() {
        listener.cancel()
    }

    private func fetch() async throws -> (status: Int, segments: Int, body: String) {
        var request = URLRequest(url: upstream)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 502
        guard status == 200 else {
            if status == 404 { throw TwitchError("The stream has ended.") }
            return (status, 0, "")
        }
        let result = filter.clean(String(decoding: data, as: UTF8.self))
        isAd = result.isAd
        adEnds = result.adEnds
        return (status, result.segments, result.playlist)
    }

    /// Answers every request with the playlist, whatever path mpv asked for, then closes the connection.
    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { _, _, _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return connection.cancel() }
                let reply: (status: Int, segments: Int, body: String) = (try? await self.fetch()) ?? (404, 0, "")
                let body = Data(reply.body.utf8)
                let reason = reply.status == 200 ? "OK" : "Error"
                let head = "HTTP/1.1 \(reply.status) \(reason)\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(body.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}

import Foundation
import Network
import SwiftyTube

struct SABRError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) {
        errorDescription = message
        FileLog.shared.append("sabr", "ERROR", message)
    }
}

/// One of the separate audio or video files YouTube lists for a video, by the fields SABR names it with.
struct SABRFormat: Sendable {
    let itag: Int
    let lastModified: Int?
    let xtags: String?
    let mimeType: String
    let width: Int?
    let height: Int?
    let bitrate: Int
    let isDrc: Bool
    let isDefaultAudio: Bool

    init?(json: [String: Any]) {
        guard let itag = json["itag"] as? Int, let mimeType = json["mimeType"] as? String else { return nil }
        self.itag = itag
        lastModified = (json["lastModified"] as? String).flatMap(Int.init)
        xtags = json["xtags"] as? String
        self.mimeType = mimeType
        width = json["width"] as? Int
        height = json["height"] as? Int
        bitrate = json["bitrate"] as? Int ?? 0
        isDrc = json["isDrc"] as? Bool ?? false
        isDefaultAudio = (json["audioTrack"] as? [String: Any])?["audioIsDefault"] as? Bool ?? true
    }

    /// `avc1.640028` out of `video/mp4; codecs="avc1.640028"`.
    var codec: String { mimeType.components(separatedBy: "\"").dropFirst().first ?? mimeType }

    /// The short side, so a vertical 1080x1920 Short counts as 1080p.
    var shortSide: Int { min(width ?? 0, height ?? 0) }

    func writeId(_ writer: inout SABRWriter) {
        writer.int(1, itag)
        writer.int(2, lastModified)
        writer.string(3, xtags)
    }
}

/// Where each media segment of a track starts and how long it lasts, read from the file's segment index (sidx).
struct SABRTrack: Sendable {
    let format: SABRFormat
    let starts: [Int]
    let durations: [Int]

    /// Reads the sidx box: a list of segments, each with its size and length in the file's timescale.
    init?(format: SABRFormat, initSegment: Data) {
        let bytes = [UInt8](initSegment)
        func number(_ at: Int, _ size: Int) -> Int {
            bytes[at..<at + size].reduce(0) { $0 << 8 | Int($1) }
        }
        var box = 0
        while box + 8 <= bytes.count {
            var size = number(box, 4)
            if size == 1, box + 16 <= bytes.count { size = number(box + 8, 8) }
            guard size >= 8 else { return nil }
            if String(decoding: bytes[box + 4..<box + 8], as: UTF8.self) == "sidx" {
                let version = bytes[box + 8]
                var at = box + 16
                guard at + 4 <= bytes.count else { return nil }
                let timescale = number(at, 4)
                at += 4
                let wide = version == 0 ? 4 : 8
                guard timescale > 0, at + wide * 2 + 4 <= bytes.count else { return nil }
                var time = number(at, wide)
                at += wide * 2 + 2
                let count = number(at, 2)
                at += 2
                guard at + count * 12 <= bytes.count, count > 0 else { return nil }
                var starts: [Int] = []
                var durations: [Int] = []
                for _ in 0..<count {
                    let duration = number(at + 4, 4)
                    starts.append(time * 1000 / timescale)
                    durations.append(duration * 1000 / timescale)
                    time += duration
                    at += 12
                }
                self.format = format
                self.starts = starts
                self.durations = durations
                return
            }
            box += size
        }
        return nil
    }

    var durationMs: Int { (starts.last ?? 0) + (durations.last ?? 0) }

    /// fMP4 HLS: the init file once, then every segment. ffmpeg only takes segments whose name says what they are.
    var playlist: String {
        let target = Int(((durations.max() ?? 1000) + 999) / 1000)
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(target)", "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-MAP:URI=\"init.mp4\""]
        for (index, duration) in durations.enumerated() {
            lines.append("#EXTINF:\(String(format: "%.3f", Double(duration) / 1000)),")
            lines.append("\(index + 1).m4s")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Talks SABR with YouTube for one video. Each request names the track it wants and the time to start from,
/// and the answer carries that track's next segments, which wait here until the player asks for them.
actor SABRSession {
    let video: SABRFormat
    let audio: SABRFormat
    private var url: String
    private let ustreamerConfig: Data
    private let language: String
    private var poToken: Data?
    /// A token bound to the account instead of the video, for when YouTube refuses the first one.
    private var otherToken: (@Sendable () async -> Data?)?
    private var cookie: Data?
    private var contexts: [Int: Data] = [:]
    private var sentContexts: Set<Int> = []
    private var requestNumber = 0
    private var inits: [Int: Data] = [:]
    private var segments: [String: Data] = [:]
    private var arrival: [String] = []
    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Segments the player hasn't asked for yet. Older ones go first, so a seek doesn't fill the memory.
    private static let keptSegments = 40
    private static let maxBackoff = Duration.seconds(5)
    /// SABR's way to say "I already have all of this one", so an answer carries only the other track.
    private static let everything = Int(Int32.max)

    init(video: SABRFormat, audio: SABRFormat, url: String, ustreamerConfig: Data, language: String, poToken: Data?, otherToken: (@Sendable () async -> Data?)?) {
        self.video = video
        self.audio = audio
        self.url = url
        self.ustreamerConfig = ustreamerConfig
        self.language = language
        self.poToken = poToken
        self.otherToken = otherToken
    }

    func initSegment(of format: SABRFormat) async throws -> Data {
        if let data = inits[format.itag] { return data }
        await lock()
        defer { unlock() }
        for _ in 0..<3 {
            if let data = inits[format.itag] { return data }
            try await fetch(format, from: 0)
        }
        throw SABRError("No init segment for itag \(format.itag)")
    }

    func segment(_ sequence: Int, of format: SABRFormat, startMs: Int) async throws -> Data {
        let key = Self.key(format.itag, sequence)
        if let data = take(key) { return data }
        await lock()
        defer { unlock() }
        for _ in 0..<3 {
            if let data = take(key) { return data }
            try await fetch(format, from: startMs)
        }
        throw SABRError("Segment \(sequence) of itag \(format.itag) never arrived")
    }

    private static func key(_ itag: Int, _ sequence: Int) -> String { "\(itag)/\(sequence)" }

    /// The player reads each segment once, so it leaves the memory as it's handed over.
    private func take(_ key: String) -> Data? {
        guard let data = segments.removeValue(forKey: key) else { return nil }
        arrival.removeAll { $0 == key }
        return data
    }

    /// One request at a time: each answer changes the cookie and contexts the next request sends back.
    private func lock() async {
        if isBusy {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            isBusy = true
        }
    }

    private func unlock() {
        if waiting.isEmpty {
            isBusy = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    private func fetch(_ format: SABRFormat, from timeMs: Int) async throws {
        let other = format.itag == video.itag ? audio : video
        var body = SABRWriter()
        body.message(1) { state in
            state.int(21, video.height)
            state.int(28, timeMs)
            state.int(40, 0)
            state.bool(46, true)
            state.bool(76, true)
        }
        for itag in inits.keys {
            body.message(2) { (itag == video.itag ? video : audio).writeId(&$0) }
        }
        body.message(3) { range in
            range.message(1) { other.writeId(&$0) }
            range.int(2, 0)
            range.int(3, Self.everything)
            range.int(4, 0)
            range.int(5, Self.everything)
            range.message(6) { time in
                time.int(1, 0)
                time.int(2, Self.everything)
                time.int(3, 1000)
            }
        }
        body.bytes(5, ustreamerConfig)
        body.message(16) { audio.writeId(&$0) }
        body.message(17) { video.writeId(&$0) }
        body.message(19) { context in
            context.message(1) { client in
                client.string(1, language)
                client.int(16, YouTubeClientNumber.web)
                client.string(17, YouTubeClient.web.clientVersion)
                client.string(18, YouTubeClient.web.osName)
                client.string(19, YouTubeClient.web.osVersion)
            }
            context.bytes(2, poToken)
            context.bytes(3, cookie)
            for type in sentContexts.sorted() {
                context.message(5) { pair in
                    pair.int(1, type)
                    pair.bytes(2, contexts[type])
                }
            }
            for type in contexts.keys.sorted() where !sentContexts.contains(type) {
                context.int(6, type)
            }
        }

        requestNumber += 1
        guard let address = URL(string: url + "&rn=\(requestNumber)") else { throw SABRError("Bad SABR address") }
        var request = URLRequest(url: address)
        request.httpMethod = "POST"
        request.httpBody = body.data
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.yt-ump", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw SABRError("SABR answered HTTP \(status)") }
        try await read(UMP.parts(data))
    }

    private struct Pending {
        let itag: Int
        let sequence: Int
        let isInit: Bool
        let length: Int?
        var data = Data()
    }

    private func read(_ parts: [UMPPart]) async throws {
        var pending: [Int: Pending] = [:]
        var protection = 1
        var backoff = 0
        for part in parts {
            switch part.type {
            case 20: // MEDIA_HEADER: a segment starts
                guard let header = SABRMessage(part.payload), let id = header.int(1),
                      let itag = header.int(3) ?? header.message(13)?.int(1) else { continue }
                pending[id] = Pending(itag: itag, sequence: header.int(9) ?? 0, isInit: header.bool(8), length: header.int(14))
            case 21: // MEDIA: bytes of a segment, after its header ID
                guard let id = UMP.varint([UInt8](part.payload.prefix(5)), at: 0) else { continue }
                pending[id.value]?.data.append(part.payload.dropFirst(id.length))
            case 22: // MEDIA_END
                guard let id = UMP.varint([UInt8](part.payload.prefix(5)), at: 0),
                      let segment = pending.removeValue(forKey: id.value) else { continue }
                if let length = segment.length, length != segment.data.count { continue }
                if segment.isInit {
                    inits[segment.itag] = segment.data
                } else {
                    keep(segment.data, as: Self.key(segment.itag, segment.sequence))
                }
            case 35: // NEXT_REQUEST_POLICY
                guard let policy = SABRMessage(part.payload) else { continue }
                cookie = policy.data(7) ?? cookie
                backoff = policy.int(4) ?? 0
            case 43: // SABR_REDIRECT
                if let redirect = SABRMessage(part.payload)?.string(1) { url = redirect }
            case 44: // SABR_ERROR
                let error = SABRMessage(part.payload)
                throw SABRError("SABR error \(error?.string(1) ?? "") \(error?.int(2) ?? 0)")
            case 46: // RELOAD_PLAYER_RESPONSE
                throw SABRError("YouTube asked to load the video again")
            case 57: // SABR_CONTEXT_UPDATE
                guard let update = SABRMessage(part.payload), let type = update.int(1), let value = update.data(3) else { continue }
                if update.int(5) != 2 || contexts[type] == nil { contexts[type] = value }
                if update.bool(4) { sentContexts.insert(type) }
            case 58: // STREAM_PROTECTION_STATUS
                protection = SABRMessage(part.payload)?.int(1) ?? 1
            case 59: // SABR_CONTEXT_SENDING_POLICY
                guard let policy = SABRMessage(part.payload) else { continue }
                sentContexts.formUnion(policy.ints(1))
                sentContexts.subtract(policy.ints(2))
                for type in policy.ints(3) {
                    contexts[type] = nil
                    sentContexts.remove(type)
                }
            default:
                break
            }
        }
        if protection == 3 {
            guard let otherToken else { throw SABRError("YouTube refused the PO token") }
            self.otherToken = nil
            poToken = await otherToken()
            FileLog.shared.append("sabr", "INFO", "PO token refused, trying the one bound to the account")
        }
        if backoff > 0 {
            try await Task.sleep(for: min(.milliseconds(backoff), Self.maxBackoff))
        }
    }

    private func keep(_ data: Data, as key: String) {
        segments[key] = data
        arrival.append(key)
        while arrival.count > Self.keptSegments {
            segments[arrival.removeFirst()] = nil
        }
    }
}

/// InnerTube names clients by number inside SABR requests.
enum YouTubeClientNumber {
    static let web = 1
}

/// A SABR video's session and its two tracks.
struct SABRMedia: Sendable {
    let session: SABRSession
    let video: SABRTrack
    let audio: SABRTrack
}

/// Serves SABR videos to mpv from 127.0.0.1 as two HLS playlists, video and audio.
/// Each segment is asked from YouTube when mpv asks for it.
@MainActor
final class SABRServer {
    static let shared = SABRServer()

    private var listener: NWListener?
    private var port: UInt16 = 0
    private var playbacks: [String: SABRMedia] = [:]
    private var order: [String] = []
    /// The playing video, the one before it and a couple preloaded.
    private static let keptPlaybacks = 4

    /// Returns mpv's address for the two tracks together.
    func register(_ media: SABRMedia) async throws -> String {
        let port = try await start()
        let id = UUID().uuidString
        playbacks[id] = media
        order.append(id)
        while order.count > Self.keptPlaybacks {
            playbacks[order.removeFirst()] = nil
        }
        let base = "http://127.0.0.1:\(port)/\(id)"
        let seconds = max(media.video.durationMs, media.audio.durationMs) / 1000
        return StreamFallback.combineVideoAndAudio(videoURL: base + "/v/index.m3u8", audioURL: base + "/a/index.m3u8", duration: seconds)
    }

    private func start() async throws -> UInt16 {
        if listener != nil { return port }
        let parameters = NWParameters.tcp
        // Only this phone can connect, never another device on the Wi-Fi.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.serve(connection) }
        }
        port = try await withCheckedThrowingContinuation { continuation in
            // Cleared after the first answer, so the continuation resumes once.
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    listener?.stateUpdateHandler = nil
                    continuation.resume(returning: listener?.port?.rawValue ?? 0)
                case .failed(let error):
                    listener?.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: .main)
        }
        self.listener = listener
        return port
    }

    /// `/<playback>/<v|a>/index.m3u8`, `init.mp4` or `<n>.m4s`. Each answer closes the connection.
    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return connection.cancel() }
                let line = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
                let path = line.components(separatedBy: " ").dropFirst().first ?? ""
                let reply = await self.answer(path)
                let head = "HTTP/1.1 \(reply.body == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: \(reply.type)\r\nContent-Length: \(reply.body?.count ?? 0)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + (reply.body ?? Data()), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private func answer(_ path: String) async -> (body: Data?, type: String) {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 3, let playback = playbacks[parts[0]] else { return (nil, "text/plain") }
        let track = parts[1] == "v" ? playback.video : playback.audio
        let file = parts[2]
        if file == "index.m3u8" {
            return (Data(track.playlist.utf8), "application/vnd.apple.mpegurl")
        }
        do {
            if file == "init.mp4" {
                return (try await playback.session.initSegment(of: track.format), "video/mp4")
            }
            guard file.hasSuffix(".m4s"), let sequence = Int(file.dropLast(4)), sequence >= 1, sequence <= track.starts.count else {
                return (nil, "text/plain")
            }
            let data = try await playback.session.segment(sequence, of: track.format, startMs: track.starts[sequence - 1])
            return (data, "video/mp4")
        } catch {
            FileLog.shared.append("sabr", "ERROR", "\(path): \(error.localizedDescription)")
            return (nil, "text/plain")
        }
    }
}

extension Data {
    /// YouTube's base64 uses - and _ and often drops the padding.
    init?(base64URL text: String) {
        var text = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        self.init(base64Encoded: text)
    }
}

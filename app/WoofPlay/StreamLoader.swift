import CoreMedia
import Foundation
import SwiftyTube
import VideoToolbox

struct LoadedStream: @unchecked Sendable {
    let url: String
    let summary: String
    let captions: [YouTubeCaptionTrack]
    /// Separate files, which downloads and audio tracks need. HLS and combined streams have none.
    var videoURL: String?
    var audioURL: String?
    var videoSize: Int64?
    var audioSize: Int64?
    var duration: Int?
    var client: YouTubeClient?
    var isLive = false
    var title: String?
    var channelTitle: String?
    var channelId: String?
    /// A video YouTube only gives in SABR segments. Downloads read the segments from here.
    var sabr: SABRMedia?
    /// The preview frames for scrubbing, when the stream's own answer had them.
    var storyboard: Storyboard?
}

struct AudioTrack: Identifiable, Hashable {
    let id: String
    let name: String
    let url: String
    let isOriginal: Bool
}

/// A grid of small frames from the video, shown above the bar while scrubbing.
struct Storyboard {
    let urlTemplate: String
    let level: Int
    let name: String
    let signature: String
    let frameSize: CGSize
    let count: Int
    let columns: Int
    let rows: Int
    let interval: Double

    /// `base|w#h#count#columns#rows#intervalMs#name#signature|...`, smallest level first.
    init?(spec: String) {
        let parts = spec.components(separatedBy: "|")
        guard parts.count > 1, let fields = parts.last?.components(separatedBy: "#"), fields.count >= 8,
              let width = Double(fields[0]), let height = Double(fields[1]), let count = Int(fields[2]),
              let columns = Int(fields[3]), let rows = Int(fields[4]), let interval = Double(fields[5]),
              columns > 0, rows > 0, interval > 0 else { return nil }
        urlTemplate = parts[0]
        level = parts.count - 2
        name = fields[6]
        signature = fields[7]
        frameSize = CGSize(width: width, height: height)
        self.count = count
        self.columns = columns
        self.rows = rows
        self.interval = interval
    }

    func frame(at seconds: Double) -> (url: URL?, column: Int, row: Int) {
        let index = min(max(Int(seconds * 1000 / interval), 0), max(count - 1, 0))
        let perSheet = columns * rows
        let sheetName = name.replacingOccurrences(of: "$M", with: String(index / perSheet))
        let url = urlTemplate
            .replacingOccurrences(of: "$L", with: String(level))
            .replacingOccurrences(of: "$N", with: sheetName) + "&sigh=" + signature
        let position = index % perSheet
        return (URL(string: url), position % columns, position / columns)
    }
}

/// Thrown with one line per client tried, shown on screen because the app runs on the phone.
struct StreamFailure: LocalizedError {
    let attempts: [String]
    /// YouTube asked to prove this isn't a bot, or to reload: a renewed sign-in can pass.
    let needsRenewal: Bool
    var errorDescription: String? { attempts.joined(separator: "\n") }

    init(attempts: [String], needsRenewal: Bool = false) {
        self.attempts = attempts
        self.needsRenewal = needsRenewal
        FileLog.shared.append("stream", "ERROR", attempts.joined(separator: " | "))
    }
}

enum StreamLoader {
    private static let sessionId = UUID().uuidString

    /// Fields SwiftyTube's typed response leaves out. Loaded after playback starts, so they don't delay it.
    static func extras(videoId: String, client: YouTubeClient) async -> (tracks: [AudioTrack], storyboard: Storyboard?) {
        guard let json = try? await InnerTubeClient.woofplay.player(videoId: videoId, client: client) else { return ([], nil) }
        let formats = JSON.first("adaptiveFormats", in: json) as? [[String: Any]] ?? []
        var best: [String: (bitrate: Int, track: AudioTrack)] = [:]
        for format in formats {
            guard let audio = format["audioTrack"] as? [String: Any],
                  let id = audio["id"] as? String,
                  let name = audio["displayName"] as? String,
                  let url = format["url"] as? String,
                  format["isDrc"] as? Bool != true else { continue }
            let bitrate = format["bitrate"] as? Int ?? 0
            if bitrate > best[id]?.bitrate ?? -1 {
                best[id] = (bitrate, AudioTrack(id: id, name: name, url: url, isOriginal: audioTags(of: url).contains(originalTag)))
            }
        }
        let tracks = best.values.map(\.track).sorted { ($0.isOriginal ? 0 : 1, $0.name) < ($1.isOriginal ? 0 : 1, $1.name) }
        return (tracks, JSON.string("spec", in: json["storyboards"]).flatMap(Storyboard.init(spec:)))
    }

    private static let originalTag = "acont=original"
    private static let compressedTag = "drc=1"

    /// What YouTube says about an audio file, kept in its address: `acont=dubbed-auto:lang=it`.
    private static func audioTags(of url: String?) -> [String] {
        let tags = url.flatMap(URLComponents.init(string:))?.queryItems?.first { $0.name == "xtags" }?.value
        return tags?.components(separatedBy: ":") ?? []
    }

    /// A video with dubs lists every language side by side, so without this the choice falls on any of them.
    /// Videos with one language have no such tag and are kept whole.
    /// Stable Volume is YouTube's own: a copy of the audio with loud and quiet parts evened out (drc=1).
    private static func originalAudio<Item>(in items: [Item], url: (Item) -> String?, stable: Bool = prefersStableVolume) -> [Item] {
        let originals = items.filter { audioTags(of: url($0)).contains(originalTag) }
        let pool = originals.isEmpty ? items : originals
        let wanted = pool.filter { audioTags(of: url($0)).contains(compressedTag) == stable }
        return wanted.isEmpty ? pool : wanted
    }

    /// The Stable Volume setting, read here so downloads and playback pick the same audio.
    static var prefersStableVolume: Bool { UserDefaults.standard.bool(forKey: "stableVolume") }

    /// iPhones with an A17 Pro or M chip and later decode AV1 in hardware. AV1 is how YouTube sends 1440p and 4K.
    static let decodesAV1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)

    /// H.264, and AV1 where the phone has the hardware for it. mpv decodes the rest in software,
    /// which drops frames and puts the picture out of step. SwiftyTube counts every mp4 as H.264, and AV1 comes in mp4 too.
    private static func hardwareDecoded<Item>(in items: [Item], codec: (Item) -> String, av1: Bool = decodesAV1) -> [Item] {
        let kept = items.filter { isHardwareDecoded(codec($0), av1: av1) }
        return kept.isEmpty ? items : kept
    }

    static func isHardwareDecoded(_ codec: String, av1: Bool = decodesAV1) -> Bool {
        let codec = codec.lowercased()
        return codec.hasPrefix("avc1") || (av1 && codec.hasPrefix("av01"))
    }

    static func selfCheck() {
        assert(hardwareDecoded(in: ["av01.0.13M.08", "avc1.64002A", "vp9"], codec: { $0 }, av1: false) == ["avc1.64002A"])
        assert(hardwareDecoded(in: ["av01.0.13M.08", "avc1.64002A", "vp9"], codec: { $0 }, av1: true) == ["av01.0.13M.08", "avc1.64002A"])
        assert(hardwareDecoded(in: ["av01.0.13M.08", "vp9"], codec: { $0 }, av1: false) == ["av01.0.13M.08", "vp9"])
        func address(_ tags: String) -> String { "https://a.com/videoplayback?xtags=\(tags)&itag=251" }
        let dub = address("acont%3Ddubbed-auto%3Alang%3Dit")
        let original = address("acont%3Doriginal%3Alang%3Den")
        let compressed = address("acont%3Doriginal%3Adrc%3D1%3Alang%3Den")
        assert(audioTags(of: dub) == ["acont=dubbed-auto", "lang=it"])
        assert(originalAudio(in: [dub, compressed, original], url: { $0 }, stable: false) == [original])
        assert(originalAudio(in: [dub, compressed, original], url: { $0 }, stable: true) == [compressed])
        assert(originalAudio(in: [dub, compressed], url: { $0 }, stable: false) == [compressed])
        assert(originalAudio(in: ["https://a.com/plain", dub], url: { $0 }, stable: false) == ["https://a.com/plain", dub])
    }

    /// The clients tried first for streams can return no storyboard, so this asks the iOS client.
    static func storyboard(videoId: String) async -> Storyboard? {
        guard let json = try? await InnerTubeClient.woofplay.player(videoId: videoId, client: .iOS) else { return nil }
        return JSON.string("spec", in: json["storyboards"]).flatMap(Storyboard.init(spec:))
    }

    /// The clients tried first for streams can return no captions at all, so these come from the iOS client.
    static func captions(videoId: String) async -> [YouTubeCaptionTrack] {
        let response: PlayerResponse? = try? await InnerTubeClient.woofplay.playerResponse(videoId: videoId, client: .iOS, options: PlayerRequestOptions(signatureTimestamp: nil))
        return response.map { YouTubeWatchParser.captionTracks(from: $0) } ?? []
    }

    /// YouTube's current visionOS app. Older versions get fewer formats and no captions.
    private static let visionOS = YouTubeClient(
        clientName: "VISIONOS",
        clientVersion: "1.04",
        clientId: 101,
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        useMusicPlayerEndpoint: true,
        includeUserAgentInContext: true,
        skipPlayerResponseValidation: true,
        osName: "visionOS",
        osVersion: "26.6.0.23O770",
        deviceMake: "Apple",
        deviceModel: "RealityDevice17,1"
    )
    /// The iOS app with a PO token, the proof of a real device YouTube asks for when it suspects a bot.
    /// Without a token it's the plain iOS client.
    private static let iOSWithToken = YouTubeClient(
        clientName: YouTubeClient.iOS.clientName,
        clientVersion: YouTubeClient.iOS.clientVersion,
        clientId: YouTubeClient.iOS.clientId,
        userAgent: YouTubeClient.iOS.userAgent,
        includeUserAgentInContext: true,
        useWebPoTokens: true,
        osName: YouTubeClient.iOS.osName,
        osVersion: YouTubeClient.iOS.osVersion,
        deviceMake: YouTubeClient.iOS.deviceMake,
        deviceModel: YouTubeClient.iOS.deviceModel
    )
    /// The TV client without the account: with Google's cookies it answers "The page needs to be reloaded".
    private static let tvAsGuest = YouTubeClient(
        clientName: YouTubeClient.tvHtml5.clientName,
        clientVersion: YouTubeClient.tvHtml5.clientVersion,
        clientId: YouTubeClient.tvHtml5.clientId,
        userAgent: YouTubeClient.tvHtml5.userAgent,
        includeUserAgentInContext: true,
        useSignatureTimestamp: true,
        useWebPoTokens: true
    )
    /// In SwiftyTube's list the other direct clients are refused, or their addresses stop working
    /// partway through a video. The older visionOS stays in case an account is treated differently.
    /// The TV clients go last, since their video addresses come encrypted.
    private static let directClients: [YouTubeClient] = [visionOS, iOSWithToken, .visionOS, tvAsGuest, .tvHtml5]
    /// Without the TV client: this path keeps only its audio, since the TV's video addresses come encrypted.
    private static let fallbackChain = ([visionOS, .visionOS, .iOS] as [YouTubeClient]).map { FallbackClient(client: $0, skipValidation: $0 == .iOS) }
        + [FallbackClient(client: .web, skipValidation: true)]

    private static let cache = StreamCache()

    /// The TV client's addresses come encrypted, and stop loading without its token.
    private static func address(of format: Format, token: PoTokenResult?, providers: StreamResolveProviders) async throws -> String {
        let url = try await StreamFallback.resolveFormatURL(format, providers: providers)
        guard let pot = token?.streamingDataPoToken.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return url }
        return url + "&pot=" + pot
    }

    /// Set by Session: renews the sign-in after a bot check, and says whether trying again can help.
    @MainActor static var renewSession: @MainActor () async -> Bool = { false }

    /// The same address again when it's fresh, and the same request when one is already on its way.
    /// After a bot check it renews the sign-in once and tries again.
    static func load(videoId: String, maxHeight: Int) async throws -> LoadedStream {
        try await cache.stream(videoId: videoId, maxHeight: maxHeight) {
            do {
                return try await resolve(videoId: videoId, maxHeight: maxHeight)
            } catch let failure as StreamFailure where failure.needsRenewal {
                guard await renewSession() else { throw failure }
                return try await resolve(videoId: videoId, maxHeight: maxHeight)
            }
        }
    }

    static func forget(videoId: String) async {
        await cache.remove(videoId: videoId)
    }

    static func forgetAll() async {
        await cache.removeAll()
    }

    /// `StreamFallback.resolveVideo` returns a 360p combined stream whenever one
    /// exists, so this looks for separate video and audio first.
    private static func resolve(videoId: String, maxHeight: Int) async throws -> LoadedStream {
        let tube = InnerTubeClient.woofplay
        var providers = StreamResolveProviders.live
        providers.poTokenProvider = { id in
            try? await PoTokenGenerator.shared.generate(videoId: id, sessionId: sessionId)
        }

        var attempts: [String] = []
        var isLive = false
        var needsRenewal = false
        for client in directClients {
            do {
                let timestamp = client.useSignatureTimestamp ? await providers.signatureTimestamp?() : nil
                let token = client.useWebPoTokens ? await providers.poTokenProvider?(videoId) : nil
                let response: PlayerResponse = try await tube.playerResponse(
                    videoId: videoId,
                    client: client,
                    options: PlayerRequestOptions(signatureTimestamp: timestamp, poToken: token?.playerRequestPoToken)
                )
                guard response.isPlayable, let data = response.streamingData else {
                    let status = response.playabilityStatus
                    // The bot check comes as LOGIN_REQUIRED in every language; the words cover the TV client's reload.
                    let reason = status?.reason?.lowercased() ?? ""
                    if status?.status == "LOGIN_REQUIRED" || reason.contains("not a bot") || reason.contains("reloaded") {
                        needsRenewal = true
                    }
                    attempts.append("\(client.clientName): \(status?.reason ?? status?.status ?? "no streams")")
                    continue
                }
                let captions = YouTubeWatchParser.captionTracks(from: response)
                let details = response.videoDetails
                // A live stream has no length, and mpv can only play it through HLS.
                if details?.lengthSeconds == "0" {
                    isLive = true
                    guard let hls = data.hlsManifestUrl else {
                        attempts.append("\(client.clientName): live, but no HLS address")
                        continue
                    }
                    return LoadedStream(url: hls, summary: "\(client.clientName) · Live HLS", captions: captions, isLive: true, title: details?.title, channelTitle: details?.author, channelId: details?.channelId)
                }
                // The short side, so a vertical 1080x1920 Short counts as 1080p.
                let formats = ((data.formats ?? []) + (data.adaptiveFormats ?? []))
                    .filter { min($0.width ?? 0, $0.height ?? 0) <= maxHeight }
                if let video = FormatSelector.bestVideoOnlyFormat(from: hardwareDecoded(in: formats, codec: \.codec)),
                   let videoURL = try? await address(of: video, token: token, providers: providers),
                   let audio = FormatSelector.bestAudioFormat(from: originalAudio(in: formats, url: \.url), preference: .high),
                   let audioURL = try? await address(of: audio, token: token, providers: providers) {
                    let duration = response.videoDetails?.lengthSeconds.flatMap(Int.init)
                    return LoadedStream(
                        url: StreamFallback.combineVideoAndAudio(videoURL: videoURL, audioURL: audioURL, duration: duration),
                        summary: "\(client.clientName) · \(min(video.width ?? 0, video.height ?? 0))p · \(video.codec)",
                        captions: captions,
                        videoURL: videoURL,
                        audioURL: audioURL,
                        videoSize: video.contentLength.flatMap(Int64.init),
                        audioSize: audio.contentLength.flatMap(Int64.init),
                        duration: duration,
                        client: client,
                        title: details?.title,
                        channelTitle: details?.author,
                        channelId: details?.channelId
                    )
                }
                if let hls = data.hlsManifestUrl {
                    return LoadedStream(url: hls, summary: "\(client.clientName) · HLS", captions: captions, title: details?.title, channelTitle: details?.author, channelId: details?.channelId)
                }
                attempts.append("\(client.clientName): no direct streams")
            } catch {
                attempts.append("\(client.clientName): \(error.localizedDescription)")
            }
        }

        // The fallback below only finds files, which a live stream doesn't have.
        if isLive { throw StreamFailure(attempts: attempts, needsRenewal: needsRenewal) }

        // On a network YouTube flags, only the signed-in web client gets through, and it only offers SABR.
        do {
            return try await sabr(videoId: videoId, maxHeight: maxHeight, providers: providers)
        } catch {
            attempts.append("WEB SABR: \(error.localizedDescription)")
        }

        // Web clients return encrypted URLs. This path decrypts them, but only gives a combined stream.
        do {
            let request = StreamResolveRequest(videoId: videoId, chain: fallbackChain)
            let result = try await StreamFallback.resolveFirstValid(request, using: tube, providers: providers)
            // This path carries no captions, so they come from a plain player request.
            let captionTracks = await captions(videoId: videoId)
            return LoadedStream(
                url: result.muxedStreamUrl ?? result.streamUrl,
                summary: "\(result.clientName) · \(result.muxedHeight ?? 0)p combined",
                captions: captionTracks
            )
        } catch {
            attempts.append("Fallback: \(error.localizedDescription)")
            throw StreamFailure(attempts: attempts, needsRenewal: needsRenewal)
        }
    }

    private static func preferredStability(_ audio: [SABRFormat]) -> [SABRFormat] {
        let wanted = audio.filter { $0.isDrc == prefersStableVolume }
        return wanted.isEmpty ? audio : wanted
    }

    /// The web client's video through SABR: YouTube hands it out in segments, asked one request at a time,
    /// and the app's local server gives them to mpv as HLS.
    private static func sabr(videoId: String, maxHeight: Int, providers: StreamResolveProviders) async throws -> LoadedStream {
        let tube = InnerTubeClient.woofplay
        // YouTube currently binds the web client's tokens to the video.
        let videoToken = try? await PoTokenGenerator.shared.generate(videoId: videoId, sessionId: nil).streamingDataPoToken
        let timestamp = await providers.signatureTimestamp?()
        let json = try await tube.player(videoId: videoId, client: .web, options: PlayerRequestOptions(signatureTimestamp: timestamp, poToken: videoToken))
        let playability = json["playabilityStatus"] as? [String: Any]
        guard playability?["status"] as? String == "OK" else {
            throw SABRError(playability?["reason"] as? String ?? playability?["status"] as? String ?? "not playable")
        }
        let streaming = json["streamingData"] as? [String: Any]
        let ustreamer = (((json["playerConfig"] as? [String: Any])?["mediaCommonConfig"] as? [String: Any])?["mediaUstreamerRequestConfig"] as? [String: Any])?["videoPlaybackUstreamerConfig"] as? String
        guard let address = streaming?["serverAbrStreamingUrl"] as? String,
              let config = ustreamer.flatMap(Data.init(base64URL:)) else {
            throw SABRError("no SABR address")
        }
        let formats = (streaming?["adaptiveFormats"] as? [[String: Any]] ?? []).compactMap(SABRFormat.init(json:))
        guard let video = formats
                .filter({ $0.mimeType.hasPrefix("video/mp4") && isHardwareDecoded($0.codec) && $0.shortSide <= maxHeight })
                .max(by: { ($0.shortSide, $0.bitrate) < ($1.shortSide, $1.bitrate) }),
              let audio = preferredStability(formats.filter { $0.mimeType.hasPrefix("audio/mp4") && $0.isDefaultAudio })
                .max(by: { $0.bitrate < $1.bitrate }) else {
            throw SABRError("no H.264 or AV1 video, or no AAC audio")
        }

        // The address carries the same "n" challenge as ordinary ones; the decipher step solves it when given no signature.
        var url = address.replacingOccurrences(of: ".c.youtube.com/videoplayback", with: ".googlevideo.com/videoplayback")
        if let decipher = providers.cipherURL, let playerJs = providers.playerJs,
           let encoded = url.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
           let solved = try? await decipher("url=" + encoded, playerJs()) {
            url = solved
        }

        // Without the video binding, a signed-in token is bound to the account, a guest's to the visitor.
        let auth = await tube.currentAuth()
        let otherToken: (@Sendable () async -> Data?)? = (auth.dataSyncId ?? auth.visitorData).map { binding in
            {
                let token = try? await PoTokenGenerator.shared.generate(videoId: binding, sessionId: nil).streamingDataPoToken
                return token.flatMap(Data.init(base64URL:))
            }
        }
        let session = SABRSession(
            video: video,
            audio: audio,
            url: url,
            ustreamerConfig: config,
            language: Locale.current.language.languageCode?.identifier ?? "en",
            poToken: videoToken.flatMap(Data.init(base64URL:)),
            otherToken: otherToken
        )
        guard let videoTrack = SABRTrack(format: video, initSegment: try await session.initSegment(of: video)),
              let audioTrack = SABRTrack(format: audio, initSegment: try await session.initSegment(of: audio)) else {
            throw SABRError("no segment index in the init segment")
        }
        let details = json["videoDetails"] as? [String: Any]
        let media = SABRMedia(session: session, video: videoTrack, audio: audioTrack)
        return LoadedStream(
            url: try await SABRServer.shared.register(media),
            summary: "WEB · SABR · \(video.shortSide)p · \(video.codec)",
            captions: await captions(videoId: videoId),
            duration: videoTrack.durationMs / 1000,
            title: details?["title"] as? String,
            channelTitle: details?["author"] as? String,
            channelId: details?["channelId"] as? String,
            sabr: media,
            storyboard: JSON.string("spec", in: json["storyboards"]).flatMap(Storyboard.init(spec:))
        )
    }
}

actor StreamCache {
    private struct Entry {
        let videoId: String
        let task: Task<LoadedStream, Error>
        let started: Date
    }

    /// YouTube's addresses last for hours, so this is well inside that.
    private static let lifetime: TimeInterval = 30 * 60
    private var entries: [String: Entry] = [:]

    func stream(videoId: String, maxHeight: Int, resolve: @escaping @Sendable () async throws -> LoadedStream) async throws -> LoadedStream {
        let key = "\(videoId)|\(maxHeight)"
        entries = entries.filter { Date().timeIntervalSince($0.value.started) < Self.lifetime }
        let task = entries[key]?.task ?? Task { try await resolve() }
        entries[key] = entries[key] ?? Entry(videoId: videoId, task: task, started: Date())
        do {
            let stream = try await task.value
            // A live stream's address is the live edge, and playing it later would start behind.
            // A SABR address points at SABRServer, which forgets old playbacks long before this cache would.
            if stream.isLive || stream.sabr != nil { entries[key] = nil }
            return stream
        } catch {
            entries[key] = nil
            throw error
        }
    }

    func remove(videoId: String) {
        entries = entries.filter { $0.value.videoId != videoId }
    }

    func removeAll() {
        entries = [:]
    }

    static func selfCheck() async {
        func stream(_ url: String, isLive: Bool = false) -> LoadedStream {
            LoadedStream(url: url, summary: "", captions: [], isLive: isLive)
        }
        let cache = StreamCache()
        _ = try? await cache.stream(videoId: "a", maxHeight: 1) { stream("first") }
        let repeated = try? await cache.stream(videoId: "a", maxHeight: 1) { stream("second") }
        assert(repeated?.url == "first")
        await cache.remove(videoId: "a")
        let refreshed = try? await cache.stream(videoId: "a", maxHeight: 1) { stream("third") }
        assert(refreshed?.url == "third")
        _ = try? await cache.stream(videoId: "b", maxHeight: 1) { throw URLError(.badURL) }
        let retried = try? await cache.stream(videoId: "b", maxHeight: 1) { stream("fourth") }
        assert(retried?.url == "fourth")
        _ = try? await cache.stream(videoId: "c", maxHeight: 1) { stream("live", isLive: true) }
        let live = try? await cache.stream(videoId: "c", maxHeight: 1) { stream("fifth") }
        assert(live?.url == "fifth")
    }
}

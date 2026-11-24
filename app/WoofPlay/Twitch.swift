import Combine
import Foundation
import SwiftyTube

struct TwitchError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// A live Twitch channel. It travels through the app as a `YouTubeVideo` whose id starts with "twitch:",
/// so the player page, the floating player, Picture in Picture and the lock screen treat it like any live video.
struct TwitchChannel: Identifiable, Equatable {
    let login: String
    let name: String
    let title: String
    let game: String
    let viewers: Int
    let thumbnail: String
    var avatar: String?
    /// The channel's About text.
    var bio: String?
    var id: String { login }

    var video: YouTubeVideo {
        YouTubeVideo(
            videoId: Twitch.videoIdPrefix + login, title: title, channelTitle: name, thumbnailURL: thumbnail,
            channelAvatarURL: avatar, viewCountText: "\(viewers.formatted(.number.notation(.compactName))) watching",
            publishedTimeText: game.isEmpty ? nil : game, isLive: true
        )
    }
}

/// A Twitch channel the user follows, live or not.
struct TwitchFollow: Identifiable, Equatable {
    let login: String
    let name: String
    let avatar: String?
    /// What's on now, or nil when offline.
    let live: TwitchChannel?
    /// The YouTube channels among its social links, as lowercased path parts such as "@zwag" or "uc…".
    let youTubeKeys: Set<String>
    var id: String { login }
}

extension YouTubeVideo {
    /// Set for a live Twitch stream.
    var twitchLogin: String? { Twitch.login(inVideoId: videoId) }
    /// Any Twitch item: a live stream, a past broadcast or a clip.
    var isTwitch: Bool { Twitch.isTwitch(videoId) }
}

/// Twitch's playback: a token from its GQL API, then the HLS playlist from its usher server.
enum Twitch {
    /// The ID of Twitch's own web player. GQL accepts no other, so playback can't use the app the user registered.
    private static let webClientId = "kimne78kx3ncx6brgo4mv6wki5h1ko"
    /// Tokens for the pop-out player came with no pre-roll ad, while "site" tokens got one in 6 of 8 tries.
    static let playerType = "popout"

    static let videoIdPrefix = "twitch:"
    /// Past broadcasts and clips play like videos: they have a length and can be sought.
    static let vodPrefix = "twitchvod:"
    static let clipPrefix = "twitchclip:"

    static func isTwitch(_ videoId: String) -> Bool {
        [videoIdPrefix, vodPrefix, clipPrefix].contains { videoId.hasPrefix($0) }
    }

    static func login(inVideoId videoId: String) -> String? {
        videoId.hasPrefix(videoIdPrefix) ? String(videoId.dropFirst(videoIdPrefix.count)) : nil
    }

    /// What's on now. Throws when the channel doesn't exist or isn't live.
    static func channel(_ name: String) async throws -> TwitchChannel {
        let login = name.lowercased()
        let data = try await gql("""
        query($login: String!) {
          user(login: $login) { \(userFields) }
        }
        """, ["login": login])
        guard let user = data["user"] as? [String: Any] else { throw TwitchError("There's no Twitch channel called \(name).") }
        let display = user["displayName"] as? String ?? name
        guard let stream = live(user) else { throw TwitchError("\(display) is offline.") }
        return stream
    }

    private static let userFields = "login displayName description profileImageURL(width: 70) stream { title viewersCount game { displayName } previewImageURL(width: 640, height: 360) }"

    /// A GQL user's stream, or nil when they're offline.
    private static func live(_ user: [String: Any]) -> TwitchChannel? {
        guard let login = user["login"] as? String, let stream = user["stream"] as? [String: Any] else { return nil }
        return TwitchChannel(
            login: login, name: user["displayName"] as? String ?? login, title: stream["title"] as? String ?? "",
            game: (stream["game"] as? [String: Any])?["displayName"] as? String ?? "", viewers: stream["viewersCount"] as? Int ?? 0,
            thumbnail: stream["previewImageURL"] as? String ?? "", avatar: user["profileImageURL"] as? String,
            bio: (user["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: Linked YouTube channels

    /// What the Twitch channel of a YouTube channel streams now, or nil when it's offline or there's none. Each guess (a Twitch link on the channel page, the handle,
    /// the name without spaces) counts only if that Twitch channel lists this YouTube channel among its
    /// social links, so a stranger with the same name never matches.
    static func liveStream(ofYouTubeChannel id: String, handle: String?, title: String?, pageText: String) async -> TwitchChannel? {
        var guesses = logins(in: pageText)
        // "TC Zwag" streams as "zwag", so each word of the title is a guess too. The links check every guess.
        let words = title?.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }).map(String.init) ?? []
        guesses += ([handle?.replacingOccurrences(of: "@", with: ""), title?.filter { $0.isLetter || $0.isNumber || $0 == "_" }] + words)
            .compactMap { $0?.lowercased() }
        guesses = guesses.reduce(into: [String]()) { if isLogin($1), !$0.contains($1) { $0.append($1) } }
        guard !guesses.isEmpty,
              let data = try? await gql("query($logins: [String!]) { users(logins: $logins) { \(userFields) channel { socialMedias { url } } } }", ["logins": guesses]),
              let users = data["users"] as? [Any] else { return nil }
        for case let user as [String: Any] in users {
            let urls = (JSON.first("socialMedias", in: user) as? [[String: Any]] ?? []).compactMap { $0["url"] as? String }
            if urls.contains(where: { leads($0, toChannel: id, handle: handle) }) { return live(user) }
        }
        return nil
    }

    /// Profile, stream and YouTube links of these channels, 100 per request as GQL allows.
    static func follows(_ logins: [String]) async -> [TwitchFollow] {
        var found: [TwitchFollow] = []
        for start in stride(from: 0, to: logins.count, by: 100) {
            let chunk = Array(logins[start..<min(start + 100, logins.count)])
            guard let data = try? await gql("query($logins: [String!]) { users(logins: $logins) { \(userFields) channel { socialMedias { url } } } }", ["logins": chunk]),
                  let users = data["users"] as? [Any] else { continue }
            for case let user as [String: Any] in users {
                guard let login = user["login"] as? String else { continue }
                let urls = (JSON.first("socialMedias", in: user) as? [[String: Any]] ?? []).compactMap { $0["url"] as? String }
                let keys = urls.compactMap(youTubePath).flatMap { $0.lowercased().split(separator: "/").map(String.init) }
                found.append(TwitchFollow(
                    login: login, name: user["displayName"] as? String ?? login, avatar: user["profileImageURL"] as? String,
                    live: live(user), youTubeKeys: Set(keys)
                ))
            }
        }
        return found
    }

    // MARK: Suggestions

    /// Live channels the user doesn't follow: the most watched in the categories their followed
    /// channels stream now, or, with none of those, the most watched in the iPhone's language.
    /// A creator's Twitch page: who they are, and what's on now or was on last.
    struct Profile {
        let name: String
        let avatar: String?
        let banner: String?
        let bio: String?
        let followers: Int?
        let live: TwitchChannel?
        let lastTitle: String?
        let lastGame: String?
        let lastStarted: Date?
        let broadcasts: [YouTubeVideo]
        let clips: [YouTubeVideo]
    }

    static func profile(_ login: String) async throws -> Profile {
        let data = try await gql("""
        query($login: String!) {
          user(login: $login) {
            \(userFields) bannerImageURL followers { totalCount } lastBroadcast { title startedAt game { displayName } }
            videos(first: 12, sort: TIME, type: ARCHIVE) { edges { node { id title lengthSeconds viewCount publishedAt previewThumbnailURL(width: 640, height: 360) } } }
            clips(first: 12, criteria: {period: LAST_MONTH, sort: VIEWS_DESC}) { edges { node { slug title durationSeconds viewCount createdAt thumbnailURL(width: 480, height: 272) } } }
          }
        }
        """, ["login": login])
        guard let user = data["user"] as? [String: Any] else { throw TwitchError("There's no Twitch channel called \(login).") }
        let last = user["lastBroadcast"] as? [String: Any]
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Profile(
            name: user["displayName"] as? String ?? login,
            avatar: user["profileImageURL"] as? String,
            banner: user["bannerImageURL"] as? String,
            bio: (user["description"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            followers: (user["followers"] as? [String: Any])?["totalCount"] as? Int,
            live: live(user),
            lastTitle: (last?["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            lastGame: (last?["game"] as? [String: Any])?["displayName"] as? String,
            lastStarted: (last?["startedAt"] as? String).flatMap { dates.date(from: $0) },
            broadcasts: media(in: user["videos"], prefix: vodPrefix, id: "id", length: "lengthSeconds", date: "publishedAt", thumbnail: "previewThumbnailURL", user: user),
            clips: media(in: user["clips"], prefix: clipPrefix, id: "slug", length: "durationSeconds", date: "createdAt", thumbnail: "thumbnailURL", user: user)
        )
    }

    /// Past broadcasts and clips as videos, so the usual cards show and play them.
    private static func media(in list: Any?, prefix: String, id: String, length: String, date: String, thumbnail: String, user: [String: Any]) -> [YouTubeVideo] {
        let dates = ISO8601DateFormatter()
        let edges = (list as? [String: Any])?["edges"] as? [[String: Any]] ?? []
        return edges.compactMap { edge -> YouTubeVideo? in
            guard let node = edge["node"] as? [String: Any], let key = node[id] as? String else { return nil }
            let views = node["viewCount"] as? Int
            return YouTubeVideo(
                videoId: prefix + key, title: node["title"] as? String ?? "",
                channelTitle: user["displayName"] as? String,
                durationSeconds: node[length] as? Int,
                thumbnailURL: node[thumbnail] as? String,
                channelAvatarURL: user["profileImageURL"] as? String,
                viewCountText: views.map { "\($0.formatted(.number.notation(.compactName))) views" },
                publishedTimeText: (node[date] as? String).flatMap { dates.date(from: $0) }.map { $0.formatted(.relative(presentation: .named)) }
            )
        }
    }

    /// Live channels Twitch finds for a search. Offline ones are left out, since there's nothing to watch.
    static func search(_ query: String) async -> [TwitchChannel] {
        guard let data = try? await gql("query($q: String!) { searchFor(userQuery: $q, platform: \"web\") { channels { edges { item { ... on User { \(userFields) } } } } } }", ["q": query]),
              let edges = JSON.first("edges", in: data) as? [[String: Any]] else { return [] }
        return edges.compactMap { ($0["item"] as? [String: Any]).flatMap(live) }
    }

    static func suggestions(games: [String], excluding followed: Set<String>, count: Int = 6) async -> [TwitchChannel] {
        let fields = "edges { node { title viewersCount previewImageURL(width: 640, height: 360) game { displayName } broadcaster { login displayName description profileImageURL(width: 70) } } }"
        var answers: [Any?] = []
        if games.isEmpty {
            let language = (Locale.current.language.languageCode?.identifier ?? "en").uppercased()
            answers.append(try? await gql("query($language: Language!) { streams(first: \(count * 2), options: { languages: [$language] }) { \(fields) } }", ["language": language]))
        } else {
            for game in games {
                answers.append(try? await gql("query($name: String!) { game(name: $name) { streams(first: \(count)) { \(fields) } } }", ["name": game]))
            }
        }
        var seen = followed
        let found = answers.flatMap { answer in
            (JSON.first("edges", in: answer) as? [[String: Any]] ?? []).compactMap { edge -> TwitchChannel? in
                guard let node = edge["node"] as? [String: Any], let user = node["broadcaster"] as? [String: Any],
                      let login = user["login"] as? String, seen.insert(login).inserted else { return nil }
                return TwitchChannel(
                    login: login, name: user["displayName"] as? String ?? login, title: node["title"] as? String ?? "",
                    game: (node["game"] as? [String: Any])?["displayName"] as? String ?? "", viewers: node["viewersCount"] as? Int ?? 0,
                    thumbnail: node["previewImageURL"] as? String ?? "", avatar: user["profileImageURL"] as? String,
                    bio: (user["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                )
            }
        }
        return Array(found.sorted { $0.viewers > $1.viewers }.prefix(count))
    }

    /// The YouTube channel id a Twitch channel links to, if any.
    static func youTubeChannel(of login: String) async -> String? {
        guard let data = try? await gql("query($login: String!) { user(login: $login) { channel { socialMedias { url } } } }", ["login": login.lowercased()]),
              let medias = JSON.first("socialMedias", in: data) as? [[String: Any]] else { return nil }
        for url in medias.compactMap({ $0["url"] as? String }) {
            guard let path = youTubePath(url) else { continue }
            if path.hasPrefix("/channel/") { return String(path.dropFirst("/channel/".count).prefix { $0 != "/" }) }
            if let endpoint = try? await YouTubeAPI.resolve(path), let id = JSON.string("browseId", in: endpoint) { return id }
        }
        return nil
    }

    /// Twitch logins in some text, also inside YouTube's redirect links, where "/" is "%2F".
    static func logins(in text: String) -> [String] {
        let pattern = #/(?i)twitch\.tv(?:\\?/|%2F)([a-z0-9_]{3,25})/#
        return text.matches(of: pattern).map { String($0.1).lowercased() }
    }

    private static func isLogin(_ text: String) -> Bool {
        text.wholeMatch(of: #/[a-z0-9_]{3,25}/#) != nil && !["videos", "directory", "p", "settings"].contains(text)
    }

    /// The path of a YouTube address, such as "/@zwag" or "/channel/UC…". Social links often have no scheme.
    private static func youTubePath(_ url: String) -> String? {
        let parts = URLComponents(string: url.contains("://") ? url : "https://" + url)
        guard let host = parts?.host?.lowercased(), host == "youtube.com" || host.hasSuffix(".youtube.com"), let path = parts?.path, path.count > 1 else { return nil }
        return path
    }

    static func leads(_ url: String, toChannel id: String, handle: String?) -> Bool {
        guard let path = youTubePath(url)?.lowercased() else { return false }
        let parts = path.split(separator: "/").map(String.init)
        return parts.contains(id.lowercased()) || handle.map { parts.contains("@" + $0.lowercased().replacingOccurrences(of: "@", with: "")) } == true
    }

    /// Profile pictures by login, in one request. Missing ones are left out.
    static func avatars(_ logins: [String]) async -> [String: String] {
        guard !logins.isEmpty,
              let data = try? await gql("query($logins: [String!]) { users(logins: $logins) { login profileImageURL(width: 70) } }", ["logins": logins]),
              let users = data["users"] as? [Any] else { return [:] }
        var found: [String: String] = [:]
        // A name that no longer exists comes back as null, in its place in the list.
        for case let user as [String: Any] in users {
            if let login = user["login"] as? String, let url = user["profileImageURL"] as? String { found[login] = url }
        }
        return found
    }

    /// The `data` of a GQL answer.
    private static func gql(_ query: String, _ variables: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://gql.twitch.tv/gql")!)
        request.httpMethod = "POST"
        request.setValue(webClientId, forHTTPHeaderField: "Client-ID")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables] as [String: Any])
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answer = json["data"] as? [String: Any] else { throw TwitchError("Twitch didn't answer. Try again.") }
        return answer
    }

    static func playlistURL(channel: String, maxHeight: Int) async throws -> URL {
        let login = channel.lowercased()
        let data = try await gql("""
        query($login: String!, $playerType: String!) {
          streamPlaybackAccessToken(channelName: $login, params: {platform: "web", playerBackend: "mediaplayer", playerType: $playerType}) { value signature }
        }
        """, ["login": login, "playerType": playerType])
        guard let token = data["streamPlaybackAccessToken"] as? [String: Any],
              let value = token["value"] as? String, let signature = token["signature"] as? String else {
            throw TwitchError("Twitch didn't return \(channel). Check the name.")
        }

        var usher = URLComponents(string: "https://usher.ttvnw.net/api/channel/hls/\(login).m3u8")!
        usher.queryItems = [
            .init(name: "sig", value: signature), .init(name: "token", value: value),
            .init(name: "allow_source", value: "true"), .init(name: "fast_bread", value: "true"),
            .init(name: "player_backend", value: "mediaplayer"), .init(name: "p", value: String(Int.random(in: 0..<1_000_000)))
        ]
        let (master, response) = try await URLSession.shared.data(from: usher.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TwitchError("\(channel) is offline.") }
        guard let variant = bestVariant(String(decoding: master, as: UTF8.self), maxHeight: maxHeight) else {
            throw TwitchError("Twitch sent no stream for \(channel).")
        }
        return variant
    }

    /// A past broadcast or a clip, for a video ID with one of their prefixes.
    static func mediaURL(videoId: String, maxHeight: Int) async throws -> URL? {
        if videoId.hasPrefix(vodPrefix) {
            return try await vodURL(String(videoId.dropFirst(vodPrefix.count)), maxHeight: maxHeight)
        }
        if videoId.hasPrefix(clipPrefix) {
            return try await clipURL(String(videoId.dropFirst(clipPrefix.count)), maxHeight: maxHeight)
        }
        return nil
    }

    private static func vodURL(_ id: String, maxHeight: Int) async throws -> URL {
        let data = try await gql("""
        query($id: ID!, $playerType: String!) {
          videoPlaybackAccessToken(id: $id, params: {platform: "web", playerBackend: "mediaplayer", playerType: $playerType}) { value signature }
        }
        """, ["id": id, "playerType": playerType])
        guard let token = data["videoPlaybackAccessToken"] as? [String: Any],
              let value = token["value"] as? String, let signature = token["signature"] as? String else {
            throw TwitchError("Twitch didn't return this broadcast.")
        }
        var usher = URLComponents(string: "https://usher.ttvnw.net/vod/\(id).m3u8")!
        usher.queryItems = [
            .init(name: "sig", value: signature), .init(name: "token", value: value),
            .init(name: "allow_source", value: "true"), .init(name: "player_backend", value: "mediaplayer"),
            .init(name: "p", value: String(Int.random(in: 0..<1_000_000)))
        ]
        let (master, response) = try await URLSession.shared.data(from: usher.url!)
        // Subscriber-only broadcasts answer 403.
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TwitchError("This broadcast is for subscribers only, or no longer there.") }
        guard let variant = bestVariant(String(decoding: master, as: UTF8.self), maxHeight: maxHeight) else {
            throw TwitchError("Twitch sent no video for this broadcast.")
        }
        return variant
    }

    /// A clip is a plain MP4 per quality, signed with a token.
    private static func clipURL(_ slug: String, maxHeight: Int) async throws -> URL {
        let data = try await gql("""
        query($slug: ID!) {
          clip(slug: $slug) {
            playbackAccessToken(params: {platform: "web", playerBackend: "mediaplayer", playerType: "site"}) { value signature }
            videoQualities { quality sourceURL }
          }
        }
        """, ["slug": slug])
        guard let clip = data["clip"] as? [String: Any],
              let token = clip["playbackAccessToken"] as? [String: Any],
              let value = token["value"] as? String, let signature = token["signature"] as? String,
              let qualities = clip["videoQualities"] as? [[String: Any]] else { throw TwitchError("Twitch didn't return this clip.") }
        let sources = qualities.compactMap { quality -> (height: Int, url: String)? in
            guard let url = quality["sourceURL"] as? String else { return nil }
            return (Int(quality["quality"] as? String ?? "") ?? 0, url)
        }
        guard let source = sources.filter({ $0.height <= maxHeight }).max(by: { $0.height < $1.height }) ?? sources.min(by: { $0.height < $1.height }),
              var parts = URLComponents(string: source.url) else { throw TwitchError("Twitch sent no video for this clip.") }
        parts.queryItems = [.init(name: "sig", value: signature), .init(name: "token", value: value)]
        guard let url = parts.url else { throw TwitchError("Twitch sent no video for this clip.") }
        return url
    }

    /// The highest bitrate at or under `maxHeight`, or the smallest stream when all are taller.
    static func bestVariant(_ master: String, maxHeight: Int) -> URL? {
        var variants: [(height: Int, bandwidth: Int, url: URL)] = []
        var info: String?
        for line in master.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                info = line
            } else if let current = info, !line.hasPrefix("#"), let url = URL(string: line) {
                let height = attribute("RESOLUTION", in: current).flatMap { Int($0.split(separator: "x").last ?? "") } ?? 0
                let bandwidth = attribute("BANDWIDTH", in: current).flatMap(Int.init) ?? 0
                // Audio only has no picture.
                if height > 0 { variants.append((height, bandwidth, url)) }
                info = nil
            }
        }
        let fitting = variants.filter { $0.height <= maxHeight }
        return (fitting.max { $0.bandwidth < $1.bandwidth } ?? variants.min { $0.bandwidth < $1.bandwidth })?.url
    }

    /// The value of `NAME=value` or `NAME="value"` in an HLS tag.
    static func attribute(_ name: String, in line: String) -> String? {
        guard let range = line.range(of: "\(name)=") else { return nil }
        let rest = line[range.upperBound...]
        if rest.hasPrefix("\"") {
            return rest.dropFirst().split(separator: "\"", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
        }
        return rest.split(separator: ",", maxSplits: 1).first.map(String.init)
    }

    static func selfCheck() {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=8000000,RESOLUTION=1920x1080,CODECS="avc1.64002A,mp4a.40.2",VIDEO="chunked"
        https://a/1080.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720,CODECS="avc1.4D401F,mp4a.40.2",VIDEO="720p60"
        https://a/720.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=160000,CODECS="mp4a.40.2",VIDEO="audio_only"
        https://a/audio.m3u8
        """
        assert(logins(in: #"q=https%3A%2F%2Fwww.twitch.tv%2FZwag&v "https://twitch.tv/other_1""#) == ["zwag", "other_1"])
        assert(logins(in: #""https:\/\/www.twitch.tv\/Zwag""#) == ["zwag"])
        assert(leads("https://www.youtube.com/channel/UCpUS8oR-IJSP3gFYrGAWEuQ", toChannel: "UCpUS8oR-IJSP3gFYrGAWEuQ", handle: nil))
        assert(leads("youtube.com/@Zwag", toChannel: "UCx", handle: "@zwag"))
        assert(!leads("https://twitch.tv/@zwag", toChannel: "UCx", handle: "@zwag"))
        assert(bestVariant(master, maxHeight: 2160)?.absoluteString == "https://a/1080.m3u8")
        assert(bestVariant(master, maxHeight: 720)?.absoluteString == "https://a/720.m3u8")
        assert(bestVariant(master, maxHeight: 360)?.absoluteString == "https://a/720.m3u8")
        assert(attribute("CODECS", in: #"#X:BANDWIDTH=1,CODECS="a,b",V=1"#) == "a,b")
    }
}

/// The Twitch sign-in, with the device code flow: the phone shows a code, the user types it at twitch.tv/activate.
/// It needs the Client ID of a Twitch app the user registers as a public client.
@MainActor
final class TwitchAccount: ObservableObject {
    static let shared = TwitchAccount()

    struct DeviceCode: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationUri: String
        let interval: Int
        let expiresIn: Int
    }

    private struct Token: Codable {
        var access: String
        var refresh: String
    }

    @Published var clientId: String {
        didSet { UserDefaults.standard.set(clientId, forKey: Self.clientIdKey) }
    }
    @Published private(set) var login: String?
    private var userId: String?
    @Published private var token: Token?

    private let store = SecureStore(service: "com.laskywolf.woofplay.twitch")
    private static let tokenKey = "token"
    private static let clientIdKey = "twitchClientId"
    private static let scopes = "chat:read chat:edit user:read:follows"
    private static let identity = "https://id.twitch.tv/oauth2"
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private init() {
        clientId = UserDefaults.standard.string(forKey: Self.clientIdKey) ?? ""
        if let data = try? store.load(for: Self.tokenKey) {
            token = try? JSONDecoder().decode(Token.self, from: data)
        }
    }

    var isSignedIn: Bool { token != nil }

    /// A pasted ID can carry spaces or a line break.
    private var appId: String { clientId.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Looks up who the saved token belongs to. Twitch asks apps to do this when they start and every hour.
    func restore() async {
        guard token != nil else { return }
        _ = try? await validate()
    }

    func requestCode() async throws -> DeviceCode {
        guard !appId.isEmpty else { throw TwitchError("Enter the Client ID of your Twitch app first.") }
        let data = try await post("device", ["client_id": appId, "scopes": Self.scopes])
        do {
            return try Self.decoder.decode(DeviceCode.self, from: data)
        } catch {
            throw TwitchError(Self.message(in: data) ?? "Twitch didn't accept the Client ID.")
        }
    }

    /// Asks every few seconds until the user enters the code on Twitch, or the code expires.
    func waitForApproval(of code: DeviceCode) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        while Date() < deadline {
            try await Task.sleep(for: .seconds(code.interval))
            let data = try await post("token", [
                "client_id": appId, "scopes": Self.scopes, "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ])
            if let reply = try? Self.decoder.decode(TokenReply.self, from: data) {
                save(Token(access: reply.accessToken, refresh: reply.refreshToken))
                _ = try await validate()
                return
            }
            let message = Self.message(in: data) ?? ""
            guard message == "authorization_pending" else { throw TwitchError("Twitch refused the sign-in: \(message)") }
        }
        throw TwitchError("The code expired. Try again.")
    }

    func signOut() {
        if let access = token?.access {
            let id = appId
            Task { _ = try? await post("revoke", ["client_id": id, "token": access]) }
        }
        save(nil)
        login = nil
        userId = nil
    }

    /// The name and token for the chat, checked first so an expired token is renewed.
    func chatCredentials() async -> (login: String, token: String)? {
        guard (try? await validate()) != nil, let login, let access = token?.access else { return nil }
        return (login, access)
    }

    /// Every channel the user follows, live or not.
    // ponytail: stops at 1,000 follows; page further if someone follows more.
    func followed() async throws -> [TwitchFollow] {
        if userId == nil { _ = try await validate() }
        guard let userId else { return [] }
        struct Channel: Decodable { let broadcaster_login: String }
        struct Cursor: Decodable { let cursor: String? }
        struct Page: Decodable { let data: [Channel]; let pagination: Cursor? }
        var logins: [String] = []
        var cursor: String?
        repeat {
            let data = try await helix("channels/followed?first=100&user_id=\(userId)" + (cursor.map { "&after=\($0)" } ?? ""))
            let page = try JSONDecoder().decode(Page.self, from: data)
            logins += page.data.map(\.broadcaster_login)
            cursor = page.pagination?.cursor
        } while cursor != nil && logins.count < 1000
        return await Twitch.follows(logins)
    }

    /// Whether you follow a channel, or nil when it can't be told, such as signed out.
    func isFollowing(_ login: String) async -> Bool? {
        guard isSignedIn else { return nil }
        if userId == nil { _ = try? await validate() }
        struct User: Decodable { let id: String }
        struct Users: Decodable { let data: [User] }
        guard let userId,
              let data = try? await helix("users?login=\(login)"),
              let broadcaster = (try? JSONDecoder().decode(Users.self, from: data))?.data.first?.id,
              let follows = try? await helix("channels/followed?user_id=\(userId)&broadcaster_id=\(broadcaster)") else { return nil }
        struct Follow: Decodable { let broadcaster_id: String }
        struct Page: Decodable { let data: [Follow] }
        return (try? JSONDecoder().decode(Page.self, from: follows))?.data.isEmpty == false
    }

    func liveFollowed() async throws -> [TwitchChannel] {
        if userId == nil { _ = try await validate() }
        guard let userId else { return [] }
        let data = try await helix("streams/followed?first=100&user_id=\(userId)")
        struct Stream: Decodable {
            let user_login: String, user_name: String, title: String, game_name: String, viewer_count: Int, thumbnail_url: String
        }
        struct Page: Decodable { let data: [Stream] }
        let streams = try JSONDecoder().decode(Page.self, from: data).data
        let avatars = await Twitch.avatars(streams.map(\.user_login))
        return streams.map {
            TwitchChannel(
                login: $0.user_login, name: $0.user_name, title: $0.title, game: $0.game_name, viewers: $0.viewer_count,
                thumbnail: $0.thumbnail_url.replacingOccurrences(of: "{width}", with: "640").replacingOccurrences(of: "{height}", with: "360"),
                avatar: avatars[$0.user_login]
            )
        }
    }

    // MARK: Requests

    private struct TokenReply: Decodable {
        let accessToken: String
        let refreshToken: String
    }

    /// Fills `login` and `userId`. A rejected token is renewed once, then the user is signed out.
    private func validate() async throws -> String {
        for attempt in 0..<2 {
            guard let access = token?.access else { throw TwitchError("Not signed in to Twitch.") }
            var request = URLRequest(url: URL(string: "\(Self.identity)/validate")!)
            request.setValue("OAuth \(access)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 401 {
                if attempt == 0, (try? await refresh()) != nil { continue }
                signOut()
                throw TwitchError("The Twitch sign-in expired. Sign in again.")
            }
            struct Reply: Decodable { let login: String; let userId: String }
            let reply = try Self.decoder.decode(Reply.self, from: data)
            login = reply.login
            userId = reply.userId
            return reply.login
        }
        throw TwitchError("The Twitch sign-in expired. Sign in again.")
    }

    private func refresh() async throws {
        guard let refresh = token?.refresh else { throw TwitchError("Not signed in to Twitch.") }
        let data = try await post("token", ["client_id": appId, "grant_type": "refresh_token", "refresh_token": refresh])
        let reply = try Self.decoder.decode(TokenReply.self, from: data)
        save(Token(access: reply.accessToken, refresh: reply.refreshToken))
    }

    private func helix(_ path: String) async throws -> Data {
        for attempt in 0..<2 {
            guard let access = token?.access else { throw TwitchError("Not signed in to Twitch.") }
            var request = URLRequest(url: URL(string: "https://api.twitch.tv/helix/\(path)")!)
            request.setValue(appId, forHTTPHeaderField: "Client-Id")
            request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 401, attempt == 0 {
                try await refresh()
                continue
            }
            return data
        }
        throw TwitchError("The Twitch sign-in expired. Sign in again.")
    }

    private func post(_ path: String, _ fields: [String: String]) async throws -> Data {
        var request = URLRequest(url: URL(string: "\(Self.identity)/\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").utf8)
        return try await URLSession.shared.data(for: request).0
    }

    private func save(_ token: Token?) {
        self.token = token
        if let token, let data = try? JSONEncoder().encode(token) {
            try? store.save(data, for: Self.tokenKey)
        } else {
            try? store.delete(for: Self.tokenKey)
        }
    }

    private static func message(in data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
    }
}

/// The followed channels that are live, shared by Home and the Twitch tab.
@MainActor
final class TwitchLive: ObservableObject {
    static let shared = TwitchLive()
    @Published private(set) var channels: [TwitchChannel] = []
    /// Live channels not followed, for Home and Up Next. Shown signed out too.
    @Published private(set) var suggested: [TwitchChannel] = []
    @Published private(set) var error: String?
    private var loadedAt: Date?
    /// Home and the Twitch tab both ask on appear. Within this many seconds the last answer is still good.
    private static let freshFor: TimeInterval = 60

    func refresh(force: Bool = false) async {
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < Self.freshFor { return }
        do {
            channels = TwitchAccount.shared.isSignedIn ? try await TwitchAccount.shared.liveFollowed() : []
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        var games: [String] = []
        for game in channels.map(\.game) where !game.isEmpty && !games.contains(game) { games.append(game) }
        suggested = await Twitch.suggestions(games: Array(games.prefix(Self.suggestionGames)), excluding: Set(channels.map(\.login)))
        loadedAt = Date()
    }

    /// The categories suggestions come from: one request each.
    private static let suggestionGames = 3

    func clear() {
        channels = []
        suggested = []
        error = nil
        loadedAt = nil
    }
}

import SwiftUI

/// Twitch chat is IRC over a WebSocket. Without a sign-in it reads as a guest named justinfan.
extension LiveChatModel {
    /// Connects again when Twitch asks to or the connection drops, waiting longer after each failure.
    func runTwitch(channel: String, credentials: (login: String, token: String)?) async {
        twitchChannel = channel.lowercased()
        twitchLogin = credentials?.login
        var wait = Self.firstRetryWait
        while !Task.isCancelled {
            let started = ContinuousClock.now
            let askedToReconnect = await connectTwitch(credentials: credentials)
            guard !Task.isCancelled else { return }
            canSend = false
            if askedToReconnect || started.duration(to: .now) > Self.stableConnection {
                wait = Self.firstRetryWait
            }
            if !askedToReconnect {
                try? await Task.sleep(for: wait)
                wait = min(wait * 2, Self.longestRetryWait)
            }
        }
    }

    private static var firstRetryWait: Duration { .seconds(1) }
    private static var longestRetryWait: Duration { .seconds(60) }
    /// A connection that lasted this long was working, so the next failure starts the waits over.
    private static var stableConnection: Duration { .seconds(60) }

    /// One connection, until it fails or Twitch sends RECONNECT. Returns true for RECONNECT.
    private func connectTwitch(credentials: (login: String, token: String)?) async -> Bool {
        let socket = URLSession.shared.webSocketTask(with: URL(string: "wss://irc-ws.chat.twitch.tv:443")!)
        self.socket = socket
        socket.resume()
        return await withTaskCancellationHandler {
            defer { socket.cancel(with: .goingAway, reason: nil) }
            do {
                try await send("CAP REQ :twitch.tv/tags twitch.tv/commands")
                if let credentials {
                    try await send("PASS oauth:\(credentials.token)")
                    try await send("NICK \(credentials.login)")
                } else {
                    try await send("NICK justinfan\(Int.random(in: 10_000..<100_000))")
                }
                try await send("JOIN #\(twitchChannel)")
                while !Task.isCancelled {
                    guard case .string(let text) = try await socket.receive() else { continue }
                    for line in text.split(separator: "\r\n") {
                        guard !Task.isCancelled else { return false }
                        if try await handle(String(line)) { return true }
                    }
                }
            } catch {
                if !Task.isCancelled { status = error.localizedDescription }
            }
            return false
        } onCancel: {
            // receive() waits for the next line otherwise, which may never come.
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    func postTwitch(_ text: String) {
        guard let twitchLogin else { return }
        Task {
            do {
                try await send("PRIVMSG #\(twitchChannel) :\(text)")
                // Twitch doesn't send your own message back.
                add([ChatMessage(id: UUID().uuidString, authorKey: twitchLogin, author: twitchLogin, text: text)])
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func send(_ line: String) async throws {
        try await socket?.send(.string(line))
    }

    /// Returns true when Twitch asks for a new connection.
    private func handle(_ line: String) async throws -> Bool {
        guard let message = IRCLine(line) else { return }
        switch message.command {
        case "PING":
            try await send("PONG :\(message.trailing ?? "tmi.twitch.tv")")
        case "366":
            status = nil
            canSend = twitchLogin != nil
        case "PRIVMSG", "USERNOTICE":
            if let chat = Self.twitchMessage(message) { add([chat]) }
        case "CLEARMSG":
            remove(id: message.tags["target-msg-id"] ?? "")
        case "CLEARCHAT":
            if let login = message.trailing { remove(authorKey: login) } else { remove() }
        case "NOTICE":
            status = message.trailing
        case "RECONNECT":
            status = "Reconnecting…"
            return true
        default:
            break
        }
        return false
    }

    /// A chat line, Bits as a paid card, and subs, gifts and raids as events.
    nonisolated static func twitchMessage(_ line: IRCLine) -> ChatMessage? {
        let tags = line.tags
        let login = tags["login"] ?? line.nick ?? ""
        let author = tags["display-name"].flatMap { $0.isEmpty ? nil : $0 } ?? login
        let text = withoutAction(line.trailing ?? "")
        let kind: ChatMessage.Kind
        if line.command == "USERNOTICE" {
            kind = .event(tags["system-msg"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(author) shared an announcement")
        } else if let bits = tags["bits"].flatMap(Int.init) {
            // Twitch's purple.
            kind = .paid(amount: "\(bits.formatted()) Bits", color: Color(red: 0.57, green: 0.27, blue: 1))
        } else {
            guard !text.isEmpty else { return nil }
            kind = .text
        }
        return ChatMessage(
            id: tags["id"] ?? UUID().uuidString, authorKey: login, author: author,
            badges: twitchBadges(tags["badges"] ?? ""), text: text, kind: kind
        )
    }

    /// "broadcaster/1,subscriber/12" becomes the badges both chats share.
    private nonisolated static func twitchBadges(_ list: String) -> [ChatMessage.Badge] {
        list.split(separator: ",").compactMap { badge -> ChatMessage.Badge? in
            switch badge.split(separator: "/").first {
            case "broadcaster": .owner
            case "moderator": .moderator
            case "subscriber", "founder": .member
            case "vip": .vip
            case "partner": .verified
            default: nil
            }
        }
    }

    /// "/me waves" arrives wrapped in \u{1}ACTION … \u{1}.
    private nonisolated static func withoutAction(_ text: String) -> String {
        guard text.hasPrefix("\u{1}ACTION "), text.hasSuffix("\u{1}") else { return text }
        return String(text.dropFirst(8).dropLast())
    }
}

/// One IRC line: `@tags :nick!user@host COMMAND params :trailing`.
struct IRCLine {
    var tags: [String: String] = [:]
    var nick: String?
    var command = ""
    var trailing: String?

    init?(_ line: String) {
        var rest = Substring(line)
        if rest.hasPrefix("@") {
            guard let space = rest.firstIndex(of: " ") else { return nil }
            for pair in rest.dropFirst()[..<space].split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                tags[String(parts[0])] = parts.count > 1 ? Self.unescape(String(parts[1])) : ""
            }
            rest = rest[rest.index(after: space)...]
        }
        if rest.hasPrefix(":") {
            guard let space = rest.firstIndex(of: " ") else { return nil }
            let prefix = rest.dropFirst()[..<space]
            nick = prefix.split(separator: "!").first.map(String.init)
            rest = rest[rest.index(after: space)...]
        }
        if let colon = rest.range(of: " :") {
            trailing = String(rest[colon.upperBound...])
            rest = rest[..<colon.lowerBound]
        } else if rest.hasPrefix(":") {
            trailing = String(rest.dropFirst())
            rest = ""
        }
        guard let command = rest.split(separator: " ").first else { return nil }
        self.command = String(command)
    }

    /// Tag values escape spaces and semicolons.
    private static func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\s", with: " ")
            .replacingOccurrences(of: "\\:", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    static func selfCheck() {
        let message = IRCLine("@badges=moderator/1,subscriber/12;color=#FF4500;display-name=Some\\sOne;id=abc :someone!someone@someone.tmi.twitch.tv PRIVMSG #chan :hi there :)")
        assert(message?.command == "PRIVMSG")
        assert(message?.tags["display-name"] == "Some One")
        assert(message?.nick == "someone")
        assert(message?.trailing == "hi there :)")
        assert(IRCLine("PING :tmi.twitch.tv")?.trailing == "tmi.twitch.tv")
        assert(IRCLine(":tmi.twitch.tv 366 justinfan1 #chan :End of /NAMES list")?.command == "366")

        let chat = message.flatMap(LiveChatModel.twitchMessage)
        assert(chat?.badges == [.moderator, .member] && chat?.authorKey == "someone" && chat?.kind == .text)
        let sub = IRCLine("@display-name=Ann;login=ann;msg-id=resub;system-msg=Ann\\ssubscribed\\sfor\\s5\\smonths!;id=s1 :tmi.twitch.tv USERNOTICE #chan :love this stream")
        assert(sub.flatMap(LiveChatModel.twitchMessage)?.kind == .event("Ann subscribed for 5 months!"))
        let raid = IRCLine("@display-name=Bob;login=bob;msg-id=raid;system-msg=15\\sraiders\\sfrom\\sBob\\shave\\sjoined!;id=r1 :tmi.twitch.tv USERNOTICE #chan")
        assert(raid.flatMap(LiveChatModel.twitchMessage)?.text == "")
        let cheer = IRCLine("@bits=100;display-name=Cat;id=b1 :cat!cat@cat.tmi.twitch.tv PRIVMSG #chan :Cheer100 great play")
        if case .paid(let amount, _) = cheer.flatMap(LiveChatModel.twitchMessage)?.kind { assert(amount.hasSuffix("Bits")) } else { assertionFailure("Bits") }
    }
}

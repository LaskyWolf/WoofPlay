import SwiftUI

/// One line of a live chat, from YouTube or Twitch.
struct ChatMessage: Identifiable, Equatable {
    enum Badge: Equatable {
        case owner, moderator, member, vip, verified
    }

    enum Kind: Equatable {
        case text
        /// A Super Chat, a Super Sticker or Twitch Bits: the amount and the colour of its card.
        case paid(amount: String, color: Color)
        /// A membership, a sub, a gift or a raid, in the platform's own words.
        case event(String)
    }

    let id: String
    /// Who wrote it, to remove their messages when a moderator clears them.
    var authorKey = ""
    let author: String
    var avatar: String?
    var badges: [Badge] = []
    let text: String
    var kind = Kind.text
}

extension ChatMessage {
    /// The name as both chats show it: YouTube's "@" left out.
    var displayName: String { author.hasPrefix("@") ? String(author.dropFirst()) : author }

    /// Follows on from the message before it: same person, both plain messages.
    func continues(_ previous: ChatMessage) -> Bool {
        kind == .text && previous.kind == .text && !authorKey.isEmpty && authorKey == previous.authorKey
    }
}

enum LiveChatSource: Equatable {
    case youTube(token: String)
    case twitch(login: String)
}

/// Reads a live chat. YouTube is asked again when it says to; Twitch keeps an IRC connection open.
@MainActor
final class LiveChatModel: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published var status: String? = "Connecting…"
    /// After signing in: Twitch's own account, or a YouTube chat that offers a message field.
    @Published var canSend = false
    /// What YouTube's message field sends with each message.
    private var youTubeSendParams: String?
    var socket: URLSessionWebSocketTask?
    var twitchChannel = ""
    var twitchLogin: String?
    private static let limit = 200
    private static let shortestWait = 1000

    func run(_ source: LiveChatSource) async {
        switch source {
        case .youTube(let token): await runYouTube(token: token)
        case .twitch(let login): await runTwitch(channel: login, credentials: await TwitchAccount.shared.chatCredentials())
        }
    }

    /// Empties the chat before another stream's starts in the same model.
    func reset() {
        messages = []
        status = "Connecting…"
        canSend = false
        youTubeSendParams = nil
        twitchChannel = ""
        twitchLogin = nil
        twitchAvatars = [:]
        askedAvatars = []
    }

    func post(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !text.isEmpty else { return }
        if let youTubeSendParams {
            postYouTube(text, params: youTubeSendParams)
        } else {
            postTwitch(text)
        }
    }

    /// YouTube sends the message back in the chat, so it isn't added here.
    private func postYouTube(_ text: String, params: String) {
        Task {
            do {
                _ = try await YouTubeAPI.post("live_chat/send_message", body: [
                    "params": params,
                    "richMessage": ["textSegments": [["text": text]]],
                    "clientMessageId": UUID().uuidString
                ])
            } catch {
                status = error.localizedDescription
            }
        }
    }

    func add(_ added: [ChatMessage]) {
        let known = Set(messages.map(\.id))
        messages = Array((messages + added.filter { !known.contains($0.id) }).suffix(Self.limit))
        if !twitchChannel.isEmpty { fillTwitchAvatars() }
    }

    /// Twitch's chat sends no pictures, so they come from its API: each new name once, in one request.
    private var twitchAvatars: [String: String] = [:]
    private var askedAvatars: Set<String> = []

    private func fillTwitchAvatars() {
        let missing = Array(Set(messages.map(\.authorKey)).subtracting(askedAvatars).filter { !$0.isEmpty }.prefix(100))
        applyTwitchAvatars()
        guard !missing.isEmpty else { return }
        askedAvatars.formUnion(missing)
        Task {
            twitchAvatars.merge(await Twitch.avatars(missing)) { $1 }
            applyTwitchAvatars()
        }
    }

    private func applyTwitchAvatars() {
        guard messages.contains(where: { $0.avatar == nil && twitchAvatars[$0.authorKey] != nil }) else { return }
        messages = messages.map { message in
            var message = message
            if message.avatar == nil { message.avatar = twitchAvatars[message.authorKey] }
            return message
        }
    }

    /// A moderator deleted one message, all of one person's, or the whole chat.
    func remove(id: String? = nil, authorKey: String? = nil) {
        if let id {
            messages.removeAll { $0.id == id }
        } else if let authorKey {
            messages.removeAll { $0.authorKey == authorKey }
        } else {
            messages = []
        }
    }

    private func runYouTube(token start: String) async {
        var token = start
        while !Task.isCancelled {
            do {
                let json = try await YouTubeAPI.post("live_chat/get_live_chat", body: ["continuation": token])
                guard let chat = JSON.first("liveChatContinuation", in: json) as? [String: Any],
                      let next = (chat["continuations"] as? [[String: Any]])?.first?.values.first as? [String: Any],
                      let nextToken = next["continuation"] as? String else {
                    status = "The chat has ended."
                    return
                }
                if youTubeSendParams == nil,
                   let params = JSON.string("params", in: JSON.first("sendLiveChatMessageEndpoint", in: chat["actionPanel"])) {
                    youTubeSendParams = params
                    canSend = true
                }
                for action in chat["actions"] as? [[String: Any]] ?? [] {
                    if let item = (action["addChatItemAction"] as? [String: Any])?["item"] as? [String: Any],
                       let message = Self.youTubeMessage(item) {
                        add([message])
                    } else if let removed = (action["removeChatItemAction"] ?? action["markChatItemAsDeletedAction"]) as? [String: Any],
                              let id = removed["targetItemId"] as? String {
                        remove(id: id)
                    }
                }
                status = nil
                token = nextToken
                let wait = max(next["timeoutMs"] as? Int ?? Self.shortestWait, Self.shortestWait)
                try? await Task.sleep(for: .milliseconds(wait))
            } catch {
                if !Task.isCancelled { status = error.localizedDescription }
                return
            }
        }
    }

    /// Text, Super Chats, Super Stickers, memberships and gifted memberships. Other items return nil.
    nonisolated static func youTubeMessage(_ item: [String: Any]) -> ChatMessage? {
        guard let (type, value) = item.first, let renderer = value as? [String: Any] else { return nil }
        // A gift purchase keeps the author in its header.
        let source = (JSON.first("liveChatSponsorshipsHeaderRenderer", in: renderer) as? [String: Any]) ?? renderer
        let author = JSON.text(source["authorName"]) ?? ""
        let body = JSON.text(renderer["message"]) ?? ""
        let kind: ChatMessage.Kind
        switch type {
        case "liveChatTextMessageRenderer":
            guard !body.isEmpty else { return nil }
            kind = .text
        case "liveChatPaidMessageRenderer", "liveChatPaidStickerRenderer":
            let color = (renderer["bodyBackgroundColor"] ?? renderer["backgroundColor"]) as? Int
            kind = .paid(amount: JSON.text(renderer["purchaseAmountText"]) ?? "", color: color.map(Color.init(argb:)) ?? .orange)
        case "liveChatMembershipItemRenderer":
            kind = .event(JSON.text(renderer["headerPrimaryText"]) ?? JSON.text(renderer["headerSubtext"]) ?? "New member")
        case "liveChatSponsorshipsGiftPurchaseAnnouncementRenderer":
            kind = .event(JSON.text(source["primaryText"]) ?? "Gifted memberships")
        case "liveChatSponsorshipsGiftRedemptionAnnouncementRenderer":
            guard !body.isEmpty else { return nil }
            return ChatMessage(id: renderer["id"] as? String ?? UUID().uuidString, author: author, text: "", kind: .event("\(author) \(body)"))
        default:
            return nil
        }
        return ChatMessage(
            id: renderer["id"] as? String ?? UUID().uuidString,
            authorKey: source["authorExternalChannelId"] as? String ?? "",
            author: author,
            avatar: JSON.lastThumbnail(source["authorPhoto"]),
            badges: youTubeBadges(source["authorBadges"]),
            text: body,
            kind: kind
        )
    }

    private nonisolated static func youTubeBadges(_ object: Any?) -> [ChatMessage.Badge] {
        (object as? [[String: Any]] ?? []).compactMap { badge in
            guard let renderer = badge["liveChatAuthorBadgeRenderer"] as? [String: Any] else { return nil }
            // A member badge is the channel's own picture, with no icon.
            if renderer["customThumbnail"] != nil { return .member }
            switch (renderer["icon"] as? [String: Any])?["iconType"] as? String {
            case "OWNER": return .owner
            case "MODERATOR": return .moderator
            case "VERIFIED": return .verified
            default: return nil
            }
        }
    }

    static func selfCheck() {
        // Built from JSON text, as the real answers arrive.
        func item(_ json: String) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        }
        let text = youTubeMessage(item("""
        {"liveChatTextMessageRenderer": {"id": "1", "message": {"runs": [{"text": "hello"}]}, "authorName": {"simpleText": "Ann"},
         "authorExternalChannelId": "UC1", "authorBadges": [
           {"liveChatAuthorBadgeRenderer": {"icon": {"iconType": "MODERATOR"}, "tooltip": "Moderator"}},
           {"liveChatAuthorBadgeRenderer": {"customThumbnail": {"thumbnails": []}, "tooltip": "Member (2 months)"}}]}}
        """))
        assert(text?.text == "hello" && text?.badges == [.moderator, .member] && text?.authorKey == "UC1")
        let paid = youTubeMessage(item("""
        {"liveChatPaidMessageRenderer": {"id": "2", "authorName": {"simpleText": "Bob"}, "purchaseAmountText": {"simpleText": "€5.00"},
         "bodyBackgroundColor": 4280191205}}
        """))
        if case .paid(let amount, _) = paid?.kind { assert(amount == "€5.00") } else { assertionFailure("Super Chat") }
        assert(youTubeMessage(item(#"{"liveChatPlaceholderItemRenderer": {"id": "3"}}"#)) == nil)
    }
}

/// The chat of a YouTube or Twitch live stream, with the same rows for both.
struct LiveChatSheet: View {
    /// Owned by the player page, which starts it before the sheet opens.
    @ObservedObject var model: LiveChatModel
    @State private var draft = ""
    @State private var sent = 0
    /// Between messages of one person, and before the next person.
    private static let lineGap: CGFloat = 4
    private static let authorGap: CGFloat = 16

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                        let continues = index > 0 && message.continues(model.messages[index - 1])
                        ChatRow(message: message, isContinuation: continues)
                            .padding(.top, index == 0 ? 0 : continues ? Self.lineGap : Self.authorGap)
                    }
                    if let status = model.status {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Layout.screenPadding)
            }
            .defaultScrollAnchor(.bottom)
            .safeAreaInset(edge: .bottom) {
                if model.canSend { composer }
            }
            // No Done: the grabber and a swipe down close it.
            .navigationTitle("Live Chat")
            .sensoryFeedback(.impact(weight: .light), trigger: sent)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var composer: some View {
        let isEmpty = draft.trimmingCharacters(in: .whitespaces).isEmpty
        return HStack(spacing: Layout.chipSpacing) {
            TextField("Send a message", text: $draft)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, Layout.screenPadding)
                .frame(minHeight: Self.fieldHeight)
                .glassEffect(.regular, in: .capsule)
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: Self.fieldHeight, height: Self.fieldHeight)
                    .background(isEmpty ? AnyShapeStyle(Color.secondary.opacity(0.4)) : AnyShapeStyle(.tint), in: .circle)
            }
            .buttonStyle(ZoomPressStyle())
            .disabled(isEmpty)
            .accessibilityLabel("Send")
            .animation(.easeOut(duration: 0.15), value: isEmpty)
        }
        .padding(.horizontal, Layout.screenPadding)
        .padding(.vertical, Layout.chipSpacing)
    }

    private static let fieldHeight: CGFloat = 44

    private func send() {
        model.post(draft)
        draft = ""
        sent += 1
    }
}

/// One layout for both chats: the picture on the left, the name above and the message below.
/// A message that follows one by the same person shows only its text, lined up under theirs.
private struct ChatRow: View {
    let message: ChatMessage
    var isContinuation = false
    private static let avatarSize: CGFloat = 32
    private static let gap: CGFloat = 10

    var body: some View {
        switch message.kind {
        case .text:
            HStack(alignment: .top, spacing: Self.gap) {
                if isContinuation {
                    Color.clear.frame(width: Self.avatarSize, height: 1)
                } else {
                    picture
                }
                VStack(alignment: .leading, spacing: 2) {
                    if !isContinuation { author }
                    Text(message.text).font(.subheadline)
                }
            }
            .accessibilityElement(children: .combine)
        case .paid(let amount, let color):
            let ink = color.isLight ? Color.black : Color.white
            HStack(alignment: .top, spacing: Self.gap) {
                picture
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.displayName).font(.caption.weight(.semibold)).opacity(0.8).lineLimit(1)
                    if !message.text.isEmpty {
                        Text(message.text).font(.subheadline)
                    }
                }
                Spacer(minLength: Layout.chipSpacing)
                Text(amount).font(.subheadline.weight(.bold)).monospacedDigit()
            }
            .foregroundStyle(ink)
            .padding(Layout.rowSpacing)
            .background(color, in: .rect(cornerRadius: Layout.tileRadius))
            .accessibilityElement(children: .combine)
        case .event(let headline):
            HStack(alignment: .top, spacing: Self.gap) {
                Image(systemName: "star.fill")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.subheadline.weight(.semibold))
                    if !message.text.isEmpty {
                        Text(message.text).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Layout.rowSpacing)
            .background(.tint.opacity(0.12), in: .rect(cornerRadius: Layout.tileRadius))
            .accessibilityElement(children: .combine)
        }
    }

    /// The person's picture, or their initial while Twitch's picture is on its way.
    private var picture: some View {
        Circle()
            .fill(Color(.tertiarySystemFill))
            .overlay {
                Text(message.displayName.prefix(1).uppercased())
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .overlay {
                if message.avatar != nil {
                    CachedImage(url: message.avatar, maxPixels: 96).clipShape(.circle)
                }
            }
            .frame(width: Self.avatarSize, height: Self.avatarSize)
            .accessibilityHidden(true)
    }

    private var author: some View {
        HStack(spacing: 3) {
            ForEach(Array(message.badges.enumerated()), id: \.offset) { _, badge in
                Image(systemName: badge.symbol)
                    .font(.caption2)
                    .foregroundStyle(badge.color)
                    .accessibilityLabel(badge.name)
            }
            Text(message.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

private extension ChatMessage.Badge {
    var symbol: String {
        switch self {
        case .owner: "dot.radiowaves.left.and.right"
        case .moderator: "wrench.and.screwdriver.fill"
        case .member: "star.fill"
        case .vip: "diamond.fill"
        case .verified: "checkmark.seal.fill"
        }
    }

    var color: Color {
        switch self {
        case .owner: .red
        case .moderator: .green
        case .member: .accentColor
        case .vip: .pink
        case .verified: .secondary
        }
    }

    var name: String {
        switch self {
        case .owner: "Streamer"
        case .moderator: "Moderator"
        case .member: "Member"
        case .vip: "VIP"
        case .verified: "Verified"
        }
    }
}

extension Color {
    /// YouTube sends a Super Chat's colour as one number, 0xAARRGGBB.
    init(argb: Int) {
        self.init(
            .sRGB,
            red: Double(argb >> 16 & 0xFF) / 255, green: Double(argb >> 8 & 0xFF) / 255, blue: Double(argb & 0xFF) / 255,
            opacity: Double(argb >> 24 & 0xFF) / 255
        )
    }

    /// Light colours, such as YouTube's yellow Super Chat, need dark text.
    var isLight: Bool {
        guard let components = UIColor(self).cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components,
              components.count >= 3 else { return false }
        return 0.299 * components[0] + 0.587 * components[1] + 0.114 * components[2] > 0.6
    }
}

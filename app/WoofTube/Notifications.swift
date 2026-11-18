import SwiftUI
import SwiftyTube

private struct NotificationItem: Identifiable {
    let id: String
    let name: String?
    let message: String
    let videoTitle: String
    let time: String?
    let avatar: String?
    let thumbnail: String?
    let videoId: String?
    let clickRequest: String?
    var isRead: Bool

    init(renderer: [String: Any], seen: Set<String>) {
        let full = JSON.text(renderer["shortMessage"]) ?? ""
        // "Name uploaded: Title" becomes the name on its own line, as in YouTube's app.
        if let range = full.range(of: " uploaded: ") ?? full.range(of: " ha caricato: ") {
            name = String(full[..<range.lowerBound])
            videoTitle = String(full[range.upperBound...])
            message = "Uploaded: " + videoTitle
        } else {
            name = nil
            videoTitle = full
            message = full
        }
        id = renderer["notificationId"] as? String ?? UUID().uuidString
        time = JSON.text(renderer["sentTimeText"])
        avatar = JSON.lastThumbnail(renderer["thumbnail"])
        thumbnail = JSON.lastThumbnail(renderer["videoThumbnail"])
        videoId = JSON.string("videoId", in: renderer["navigationEndpoint"])
        clickRequest = JSON.string("serializedInteractionsRequest", in: renderer["recordClickEndpoint"])
        isRead = renderer["read"] as? Bool ?? false || seen.contains(id)
    }
}

private struct NotificationSection: Identifiable {
    let title: String
    var items: [NotificationItem]
    var id: String { title }
}

/// YouTube's `read` only follows clicks, so rows seen on the page are remembered here, per account.
private enum SeenNotifications {
    private static let key = "seenNotifications"
    private static let limit = 500

    static var all: Set<String> {
        Set(ProfileStorage.defaults.stringArray(forKey: key) ?? [])
    }

    static func add(_ ids: Set<String>) {
        guard !ids.isEmpty, !SearchSettings.isIncognito else { return }
        let saved = ProfileStorage.defaults.stringArray(forKey: key) ?? []
        let updated = saved.filter { !ids.contains($0) } + ids
        ProfileStorage.defaults.set(Array(updated.suffix(limit)), forKey: key)
    }
}

struct NotificationsView: View {
    @EnvironmentObject private var session: Session
    @Environment(Router.self) private var router
    @State private var sections: [NotificationSection] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var seenOnPage: Set<String> = []

    var body: some View {
        List {
            ForEach(sections) { section in
                Section {
                    ForEach(section.items) { item in
                        NotificationRow(item: item) {
                            markRead([item.id])
                            open(item)
                        }
                        .onAppear {
                            if !item.isRead { seenOnPage.insert(item.id) }
                        }
                        .listRowInsets(EdgeInsets(top: Layout.rowPadding, leading: Layout.screenPadding, bottom: Layout.rowPadding, trailing: Layout.screenPadding))
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    Text(section.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if sections.isEmpty {
                if isLoading {
                    LoadingTextRows(showsThumbnail: true)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, Layout.rowSpacing)
                } else {
                    ContentUnavailableView {
                        if errorText != nil {
                            Label("Couldn't Load", systemImage: "exclamationmark.triangle")
                        } else {
                            Label("No Notifications", systemImage: "bell")
                        }
                    } description: {
                        if let errorText { Text(errorText) }
                    } actions: {
                        Button("Try Again") {
                            isLoading = true
                            Task { await load() }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task {
            session.unseenNotifications = 0
            await load()
        }
        .tappingRefresh { await load() }
        .onDisappear {
            SeenNotifications.add(seenOnPage)
            markRead(seenOnPage)
            seenOnPage = []
        }
    }

    /// By ID, because a refresh can replace the list while a row still holds its place in it.
    private func markRead(_ ids: Set<String>) {
        for section in sections.indices {
            for row in sections[section].items.indices where ids.contains(sections[section].items[row].id) {
                sections[section].items[row].isRead = true
            }
        }
    }

    private func open(_ item: NotificationItem) {
        if let request = item.clickRequest {
            Task {
                _ = try? await YouTubeAPI.post("notification/record_interactions", body: ["serializedRecordNotificationInteractionsRequests": [request]])
            }
        }
        if let id = item.videoId {
            router.openVideo(YouTubeVideo(videoId: id, title: item.videoTitle, thumbnailURL: item.thumbnail))
        }
    }

    private func load() async {
        defer { isLoading = false }
        do {
            // The website's inbox. The older menu request answers with a short list, mostly Shorts.
            var json = try await YouTubeAPI.post("browse", body: ["browseId": "FEnotifications_inbox"])
            if Self.sections(in: json).isEmpty {
                json = try await YouTubeAPI.post(
                    "notification/get_notification_menu",
                    body: ["notificationsMenuRequestType": "NOTIFICATIONS_MENU_REQUEST_TYPE_INBOX"]
                )
            }
            sections = Self.sections(in: json)
            errorText = nil
        } catch {
            // Leaving the page cancels the request, which says nothing about the notifications.
            if (error as? URLError)?.code != .cancelled, !(error is CancellationError) {
                errorText = error.localizedDescription
            }
        }
    }

    /// Keeps YouTube's own section titles. Items it leaves untitled are grouped by age.
    private static func sections(in json: [String: Any]) -> [NotificationSection] {
        var result: [NotificationSection] = []
        let seen = SeenNotifications.all
        func add(_ item: NotificationItem, to title: String) {
            if let index = result.firstIndex(where: { $0.title == title }) {
                result[index].items.append(item)
            } else {
                result.append(NotificationSection(title: title, items: [item]))
            }
        }
        for section in nodes("multiPageMenuNotificationSectionRenderer", in: json) {
            let title = JSON.text(section["notificationSectionTitle"]) ?? JSON.text(section["title"])
            for renderer in nodes("notificationRenderer", in: section["items"]) {
                let item = NotificationItem(renderer: renderer, seen: seen)
                add(item, to: title ?? ageTitle(item.time))
            }
        }
        if result.isEmpty {
            for renderer in nodes("notificationRenderer", in: json) {
                let item = NotificationItem(renderer: renderer, seen: seen)
                add(item, to: ageTitle(item.time))
            }
        }
        return result
    }

    private static func ageTitle(_ time: String?) -> String {
        let words = Set((time ?? "").lowercased().split { !$0.isLetter }.map(String.init))
        if !words.isDisjoint(with: ["second", "seconds", "minute", "minutes", "hour", "hours", "secondo", "secondi", "minuto", "minuti", "ora", "ore"]) { return "Today" }
        if !words.isDisjoint(with: ["day", "days", "giorno", "giorni"]) { return "This Week" }
        return "Older"
    }

    private static func nodes(_ key: String, in object: Any?) -> [[String: Any]] {
        if let dict = object as? [String: Any] {
            if let node = dict[key] as? [String: Any] { return [node] }
            return dict.values.flatMap { nodes(key, in: $0) }
        }
        if let array = object as? [Any] {
            return array.flatMap { nodes(key, in: $0) }
        }
        return []
    }
}

private struct NotificationRow: View {
    let item: NotificationItem
    let onOpen: () -> Void
    @Environment(Router.self) private var router
    @State private var showsPlaylists = false

    var body: some View {
        Button(action: onOpen) {
            // The History page's row: the cover, the channel's picture on its edge, then the text.
            HStack(spacing: Layout.rowSpacing) {
                if let thumbnail = item.thumbnail, let id = item.videoId {
                    Thumbnail(url: thumbnail, videoId: id, maxPixels: 400)
                        .frame(width: Layout.videoSmall)
                        .deArrowMark(id, size: 24)
                        .clipShape(.rect(cornerRadius: Layout.cardRadius, style: .continuous))
                        .notched(.trailing)
                }
                avatar
                    .padding(.trailing, hasCover ? -Layout.rowSpacing / 2 : 0)
                VStack(alignment: .leading, spacing: 2) {
                    if let name = item.name {
                        Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                    Text(item.message)
                        .font(.subheadline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let time = item.time {
                        Text(time).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(.rect)
        }
        .buttonStyle(ZoomPressStyle(scale: 0.98))
        .liftedMenu {
            if let id = item.videoId {
                VideoMenuItems(video: YouTubeVideo(videoId: id, title: item.videoTitle), router: router, showsPlaylists: $showsPlaylists)
            }
        }
        .sheet(isPresented: $showsPlaylists) {
            if let id = item.videoId {
                PlaylistPickerSheet(video: YouTubeVideo(videoId: id, title: item.videoTitle))
            }
        }
    }

    /// A post has a picture but no video, so it has nothing to draw a cover for.
    private var hasCover: Bool { item.thumbnail != nil && item.videoId != nil }

    /// On the cover's edge when there is a cover, with the dot of a new notification.
    private var avatar: some View {
        let onCover = hasCover
        return Avatar(url: item.avatar, size: RowAvatar.size)
            .overlay(alignment: .topLeading) {
                if !item.isRead {
                    Circle()
                        .fill(.tint)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                        .offset(x: -2, y: -2)
                        .accessibilityLabel("New")
                }
            }
            .padding(.leading, onCover ? -RowAvatar.overlap : 0)
    }
}

/// A channel's bell: whether YouTube notifies about all of its uploads, some, or none.
/// YouTube sets every new subscription to Personalized, which mostly sends Shorts and highlights.
struct ChannelBell: Equatable {
    struct Option: Identifiable, Equatable {
        let title: String
        /// YouTube's icon name, the same in both menu shapes.
        let kind: String
        let params: String
        var id: String { params }

        var systemImage: String {
            switch kind {
            case "NOTIFICATIONS_ACTIVE": "bell.and.waves.left.and.right.fill"
            case "NOTIFICATIONS_OFF": "bell.slash"
            default: "bell"
            }
        }
    }

    let options: [Option]
    var selected: String?

    var current: Option? { options.first { $0.kind == selected } }

    /// The menu comes as old menu items or newer list items, inside the subscribe button.
    init?(json: Any?) {
        var options: [Option] = []
        func walk(_ object: Any?) {
            if let dict = object as? [String: Any] {
                if let item = (dict["menuServiceItemRenderer"] ?? dict["listItemViewModel"]) as? [String: Any],
                   let params = JSON.string("params", in: JSON.first("modifyChannelNotificationPreferenceEndpoint", in: item)),
                   let title = JSON.text(item["text"]) ?? JSON.text(item["title"]) {
                    let kind = JSON.string("iconType", in: item) ?? JSON.string("imageName", in: item) ?? ""
                    if !options.contains(where: { $0.title == title }) {
                        options.append(Option(title: title, kind: kind, params: params))
                    }
                    return
                }
                dict.values.forEach(walk)
            } else if let array = object as? [Any] {
                array.forEach(walk)
            }
        }
        walk(json)
        guard !options.isEmpty else { return nil }
        self.options = options
        selected = Self.currentKind(in: json)
        FileLog.shared.append("bell", "INFO", "options \(options.map { "\($0.title)=\($0.kind)" }), current \(selected ?? "unknown")")
    }

    /// The toggle button names its current state; the newer page keeps it in an entity instead.
    private static func currentKind(in json: Any?) -> String? {
        if let toggle = JSON.first("subscriptionNotificationToggleButtonRenderer", in: json) as? [String: Any],
           let current = toggle["currentStateId"] as? Int,
           let states = toggle["states"] as? [[String: Any]],
           let state = states.first(where: { $0["stateId"] as? Int == current }) {
            return JSON.string("iconType", in: state)
        }
        guard let state = JSON.string("state", in: JSON.first("subscriptionNotificationStateEntity", in: json)) else { return nil }
        if state.hasSuffix("_ALL") { return "NOTIFICATIONS_ACTIVE" }
        if state.hasSuffix("_OFF") || state.hasSuffix("_NONE") { return "NOTIFICATIONS_OFF" }
        return "NOTIFICATIONS_NONE"
    }

    /// Says whether YouTube took the choice.
    static func send(_ option: Option) async -> Bool {
        (try? await YouTubeAPI.post("notification/modify_channel_preference", body: ["params": option.params])) != nil
    }

    static func selfCheck() {
        let menu: [String: Any] = ["subscriptionNotificationToggleButtonRenderer": [
            "currentStateId": 2,
            "states": [["stateId": 2, "state": ["buttonRenderer": ["icon": ["iconType": "NOTIFICATIONS_NONE"]]]]],
            "command": ["items": [
                ["menuServiceItemRenderer": ["text": ["simpleText": "All"], "icon": ["iconType": "NOTIFICATIONS_ACTIVE"],
                                             "serviceEndpoint": ["modifyChannelNotificationPreferenceEndpoint": ["params": "a"]]]],
                ["listItemViewModel": ["title": ["content": "None"], "leadingImage": ["sources": [["clientResource": ["imageName": "NOTIFICATIONS_OFF"]]]],
                                       "rendererContext": ["commandContext": ["onTap": ["innertubeCommand": ["modifyChannelNotificationPreferenceEndpoint": ["params": "c"]]]]]]]
            ]]
        ]]
        let bell = ChannelBell(json: menu)
        assert(bell?.options.map(\.title) == ["All", "None"] && bell?.options.map(\.params) == ["a", "c"])
        assert(bell?.selected == "NOTIFICATIONS_NONE" && bell?.options.last?.systemImage == "bell.slash")
        assert(ChannelBell(json: ["a": 1]) == nil)
    }
}

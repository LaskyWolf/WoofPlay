import SwiftUI
import SwiftyTube

/// Woof Music's library: filters, shortcut tiles, then the sections.
struct LibraryView: View {
    private enum Filter: String, CaseIterable {
        case playlists = "Playlists"
        case channels = "Channels"
        case downloaded = "Downloaded"
        case inProgress = "In Progress"
    }

    @Environment(Router.self) private var router
    @ObservedObject private var downloads = DownloadStore.shared
    private var subscriptions: Subscriptions { .shared }
    /// Followed on Twitch; the ones whose YouTube channel is already here are left out.
    @State private var twitchFollows: [TwitchFollow] = []
    @State private var history = FeedModel()
    @State private var liked = FeedModel()
    /// Coming back from a pushed page or another tab shows what's already here.
    @State private var lastLoad = Date.distantPast
    private static let reloadAfter: TimeInterval = 60
    @State private var watchLater = FeedModel()
    @State private var playlists: [YouTubePlaylist] = []
    /// "12 videos" by playlist id. The list's own line under each playlist only says "View full playlist".
    @State private var videoCounts: [String: String] = [:]
    @EnvironmentObject private var settings: AppSettings
    @State private var isLoadingPlaylists = true
    @State private var musicPlaylistIds: Set<String> = []
    @State private var selectedFilter: Filter?
    @State private var isCreating = false
    @State private var newTitle = ""
    @State private var playlistToDelete: YouTubePlaylist?

    private var shownPlaylists: [YouTubePlaylist] {
        var seen = Set<String>()
        return playlists.filter {
            !LibraryPlaylists.isHidden($0.playlistId)
                && !musicPlaylistIds.contains($0.playlistId)
                && seen.insert($0.playlistId).inserted
        }
    }

    private func shows(_ filter: Filter) -> Bool {
        selectedFilter == nil || selectedFilter == filter
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    shortcuts
                    LibraryDownloadCard()
                    if shows(.playlists) {
                        playlistsSection
                    }
                    if shows(.channels) {
                        channelsSection
                    }
                    if selectedFilter == .downloaded {
                        videoSection(
                            title: "Downloaded",
                            videos: downloads.items.map { ($0.video, VideoExtras()) },
                            emptyText: "Long press a video and choose Download."
                        )
                    }
                    if selectedFilter == .inProgress {
                        videoSection(title: "In Progress", videos: history.unfinished, emptyText: "Videos you stop partway through show up here.")
                    }
                }
                .animation(.smooth(duration: 0.4), value: selectedFilter)
            }
            .tabRoot(title: "Library", tab: .library, onAdd: {
                newTitle = ""
                isCreating = true
            }, filters: {
                FilterChips(titles: Filter.allCases.map(\.rawValue), selected: selectedFilter?.rawValue) { title in
                    let filter = Filter(rawValue: title)
                    selectedFilter = selectedFilter == filter ? nil : filter
                }
            })
            .tappingRefresh { await load() }
            .task {
                guard Date().timeIntervalSince(lastLoad) > Self.reloadAfter else { return }
                lastLoad = Date()
                await load()
            }
            .alert("New Playlist", isPresented: $isCreating) {
                TextField("Title", text: $newTitle)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    let title = newTitle
                    router.run {
                        _ = try await InnerTubeClient.woofplay.createPlaylist(title: title)
                        await loadPlaylists()
                    }
                }
            }
            .confirmationDialog(
                "Delete \"\(playlistToDelete?.title ?? "")\"?",
                isPresented: Binding(get: { playlistToDelete != nil }, set: { if !$0 { playlistToDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    guard let id = playlistToDelete?.playlistId else { return }
                    router.run {
                        _ = try await InnerTubeClient.woofplay.deletePlaylist(playlistId: id)
                        await loadPlaylists()
                    }
                }
            }
        }
    }

    private func load() async {
        async let historyLoad: Void = history.load(.browse(YouTubeFeeds.history))
        async let likedLoad: Void = liked.load(.browse(YouTubeFeeds.playlistBrowseId(YouTubeFeeds.likedVideosPlaylistId)))
        async let laterLoad: Void = watchLater.load(.browse(YouTubeFeeds.playlistBrowseId(YouTubeFeeds.watchLaterPlaylistId)))
        async let channelsLoad: Void = subscriptions.load()
        async let followsLoad = (try? await TwitchAccount.shared.followed()) ?? []
        await loadPlaylists()
        _ = await (historyLoad, likedLoad, laterLoad, channelsLoad)
        twitchFollows = await followsLoad
        if liked.videos.isEmpty {
            await liked.load(.browse(YouTubeFeeds.playlistBrowseId(YouTubeFeeds.likedVideosPlaylistId)))
        }
    }

    private func loadPlaylists() async {
        let json = try? await InnerTubeClient.woofplay.browse(browseId: "FEplaylist_aggregation")
        // A failed refresh leaves the list on screen.
        if let json {
            (playlists, videoCounts) = await offMain { (YouTubeFeedParser.playlists(in: json), Self.videoCounts(in: json)) }
        }
        isLoadingPlaylists = false
        for playlist in playlists where !LibraryPlaylists.isHidden(playlist.playlistId) {
            if await LibraryPlaylists.isMusicOnly(playlist) {
                musicPlaylistIds.insert(playlist.playlistId)
            }
        }
    }

    // MARK: Shortcuts

    private var shortcuts: some View {
        HStack(spacing: 10) {
            ZoomLink(wholeLabel: true) {
                PlaylistPage(title: "Liked Videos", playlistId: YouTubeFeeds.likedVideosPlaylistId)
            } label: {
                ShortcutTile(title: "Liked Videos", subtitle: "Synced", icon: "hand.thumbsup.fill", tint: .lime, covers: likedCovers)
            }
            ZoomLink(wholeLabel: true) {
                PlaylistPage(title: "Watch Later", playlistId: YouTubeFeeds.watchLaterPlaylistId)
            } label: {
                ShortcutTile(title: "Watch Later", subtitle: countText(watchLater), icon: "clock.fill", tint: .yellow, covers: covers(watchLater.videos))
            }
            ZoomLink(wholeLabel: true) {
                DownloadsView()
            } label: {
                ShortcutTile(
                    title: "Downloads",
                    subtitle: downloads.importing > 0 ? "Adding files…"
                        : downloads.items.isEmpty ? "Offline" : "\(downloads.items.count) \(downloads.items.count == 1 ? "video" : "videos")",
                    icon: "arrow.down.circle.fill",
                    tint: .violet,
                    covers: covers(downloads.items.map(\.video))
                )
            }
            .contextMenu {
                Button("Add Files…", systemImage: "folder.badge.plus") { downloads.picksFiles = true }
            }
        }
        .buttonStyle(ZoomPressStyle())
        .padding(.horizontal, Layout.screenPadding)
        .padding(.top, Layout.contentTopGap)
        .padding(.bottom, Layout.sectionGap)
    }

    /// Built from the video's id, because YouTube sends some list entries with an unusable picture.
    private func covers(_ videos: [YouTubeVideo]) -> [String] {
        videos.prefix(2).map { YouTubeVideo.cover(of: $0.videoId) }
    }

    /// The hidden Liked Videos playlist has a cover of its own, for when its videos don't load.
    private var likedCovers: [String] {
        let loaded = covers(liked.videos)
        guard loaded.isEmpty else { return loaded }
        let playlist = playlists.first { $0.playlistId == YouTubeFeeds.likedVideosPlaylistId || $0.playlistId == "VL" + YouTubeFeeds.likedVideosPlaylistId }
        return [playlist?.thumbnailURL].compactMap { $0 }
    }

    /// YouTube sends a page at a time, so a long list shows the first page and a plus.
    private func countText(_ model: FeedModel) -> String? {
        let count = model.videos.count
        guard count > 0 else { return nil }
        return "\(count)\(model.hasMore ? "+" : "") \(count == 1 ? "video" : "videos")"
    }

    // MARK: Sections

    /// The count on each playlist's cover badge, by playlist id.
    nonisolated private static func videoCounts(in json: Any) -> [String: String] {
        var counts: [String: String] = [:]
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let lockup = dict["lockupViewModel"] as? [String: Any], let id = lockup["contentId"] as? String,
                   let text = JSON.string("text", in: JSON.first("thumbnailBadgeViewModel", in: lockup)) {
                    counts[id] = text
                }
                dict.values.forEach(walk)
            } else if let array = node as? [Any] {
                array.forEach(walk)
            }
        }
        walk(json)
        return counts
    }

    private func countText(of playlist: YouTubePlaylist) -> String? {
        let id = playlist.playlistId
        return videoCounts[id] ?? videoCounts[String(id.dropFirst(id.hasPrefix("VL") ? 2 : 0))] ?? playlist.videoCountText
    }

    private static let gridColumns = Array(repeating: GridItem(.flexible(), spacing: Layout.sectionGap, alignment: .top), count: 2)

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Playlists", count: shownPlaylists.count)
            if isLoadingPlaylists {
                LoadingMediaRows(isCircular: false)
            }
            if settings.libraryLayout == .grid {
                LazyVGrid(columns: Self.gridColumns, spacing: Layout.sectionGap) {
                    playlistItems
                }
                .padding(.horizontal, Layout.screenPadding)
            } else {
                LazyVStack(spacing: 0) {
                    playlistItems
                }
            }
        }
        .padding(.bottom, Layout.sectionGap)
    }

    private var playlistItems: some View {
                ForEach(shownPlaylists, id: \.playlistId) { playlist in
                    ZoomLink {
                        PlaylistPage(title: playlist.title, playlistId: playlist.playlistId)
                    } label: {
                        if settings.libraryLayout == .grid {
                            PlaylistGridCell(url: playlist.thumbnailURL, title: playlist.title, subtitle: countText(of: playlist))
                        } else {
                            MediaListRow(url: playlist.thumbnailURL, title: playlist.title, subtitle: countText(of: playlist))
                        }
                    }
                    .buttonStyle(ZoomPressStyle(scale: 0.98))
                    .padding(.horizontal, settings.libraryLayout == .grid ? 0 : Layout.screenPadding)
                    .liftedMenu {
                        Button("Download", systemImage: "arrow.down.to.line") {
                            Task {
                                downloads.download(await FeedModel.allVideos(ofPlaylist: playlist.playlistId), maxHeight: router.maxHeight)
                            }
                        }
                        Button("Delete Playlist", systemImage: "trash", role: .destructive) {
                            playlistToDelete = playlist
                        }
                    }
                }
    }

    private var channelsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            let entries = channelEntries
            SectionTitle(title: "Channels", count: entries.count)
            if entries.isEmpty {
                if subscriptions.isLoading {
                    LoadingMediaRows(isCircular: true)
                } else {
                    Text("YouTube didn't send your channels. Pull down to try again.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Layout.screenPadding)
                }
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(entries) { entry in
                    Group {
                        switch entry {
                        case .youTube(let channel):
                            Button {
                                if let id = channel.channelId { router.openChannelPage(id) }
                            } label: {
                                ChannelRow(channel: channel, avatarSize: Layout.avatarMedium, showsGenre: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(ZoomPressStyle(scale: 0.98))
                        case .twitch(let follow):
                            ZoomLink(wholeLabel: true) {
                                TwitchCreatorPage(login: follow.login, name: follow.name, avatar: follow.avatar)
                            } label: {
                                TwitchFollowRow(follow: follow)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(ZoomPressStyle(scale: 0.98))
                        }
                    }
                    .padding(.horizontal, Layout.screenPadding)
                    .padding(.vertical, Layout.rowPadding)
                }
            }
        }
        .padding(.bottom, Layout.sectionGap)
    }

    private enum ChannelEntry: Identifiable {
        case youTube(YouTubeChannel)
        case twitch(TwitchFollow)

        var id: String {
            switch self {
            case .youTube(let channel): channel.channelId ?? channel.title
            case .twitch(let follow): Twitch.videoIdPrefix + follow.login
            }
        }

        var name: String {
            switch self {
            case .youTube(let channel): channel.title
            case .twitch(let follow): follow.name
            }
        }
    }

    /// YouTube's channels in their order, with each Twitch-only creator slotted in by name.
    private var channelEntries: [ChannelEntry] {
        let keys = Set(subscriptions.channels.flatMap { channel in
            [channel.channelId, channel.handle.map { "@" + $0.replacingOccurrences(of: "@", with: "") }].compactMap { $0?.lowercased() }
        })
        var entries = subscriptions.channels.map(ChannelEntry.youTube)
        for follow in twitchFollows where follow.youTubeKeys.isDisjoint(with: keys) {
            let index = entries.firstIndex { $0.name.localizedCaseInsensitiveCompare(follow.name) == .orderedDescending } ?? entries.count
            entries.insert(.twitch(follow), at: index)
        }
        return entries
    }

    /// A live Twitch channel plays; an offline one opens on Twitch, since only live streams play here.
    private func videoSection(title: String, videos: [(video: YouTubeVideo, extras: VideoExtras)], emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: title, count: videos.count)
            if videos.isEmpty {
                Text(emptyText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Layout.screenPadding)
            }
            LazyVStack(spacing: 0) {
                ForEach(videos, id: \.video.videoId) { entry in
                    VideoButton(video: entry.video, extras: entry.extras, isCompact: true)
                        .padding(.horizontal, Layout.screenPadding)
                        .padding(.vertical, Layout.rowPadding)
                }
            }
            // The channel's picture on the cover's edge, as on the History page.
            .environment(\.showsRowAvatars, true)
        }
        .padding(.bottom, Layout.sectionGap)
    }
}

/// Decides which playlists the Library leaves out. Watch Later and Liked Videos have
/// their own tiles, and music belongs in Woof Music.
enum LibraryPlaylists {
    private static let hiddenIds: Set<String> = ["WL", "LL", "LM"]
    private static let musicPrefixes = ["OLAK5uy_", "RDCLAK"]
    private static let checksKey = "musicPlaylistChecks2"
    private static let sampleSize = 6

    static func isHidden(_ playlistId: String) -> Bool {
        let id = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
        return hiddenIds.contains(id)
    }

    /// YouTube doesn't mark music playlists, and official artist channels carry no marker in
    /// their name, so this asks for the category of a few videos spread across the first page.
    /// One video in five may differ, because music videos are sometimes filed under other
    /// categories. The answer is kept until the playlist's video count changes.
    @MainActor
    static func isMusicOnly(_ playlist: YouTubePlaylist) async -> Bool {
        let id = playlist.playlistId
        if musicPrefixes.contains(where: id.hasPrefix) { return true }
        let key = id + "|" + (playlist.videoCountText ?? "")
        var checks = UserDefaults.standard.dictionary(forKey: checksKey) as? [String: Bool] ?? [:]
        if let known = checks[key] { return known }
        guard let json = try? await FeedSource.browse(YouTubeFeeds.playlistBrowseId(id)).fetch() else { return false }
        let videos = await offMain { YouTubeFeedParser.videos(in: json) }
        let step = max(videos.count / sampleSize, 1)
        let sample = stride(from: 0, to: videos.count, by: step).prefix(sampleSize).map { videos[$0] }
        let answers = await withTaskGroup(of: Bool?.self) { group in
            for video in sample {
                group.addTask { await isMusic(video) }
            }
            return await group.reduce(into: [Bool]()) { answers, answer in
                if let answer { answers.append(answer) }
            }
        }
        guard !answers.isEmpty, !Task.isCancelled else { return false }
        let result = answers.filter { !$0 }.count * 5 <= answers.count
        checks = UserDefaults.standard.dictionary(forKey: checksKey) as? [String: Bool] ?? [:]
        checks[key] = result
        UserDefaults.standard.set(checks, forKey: checksKey)
        return result
    }

    private static func isMusic(_ video: YouTubeVideo) async -> Bool? {
        let channel = video.channelTitle ?? ""
        if channel.hasSuffix(" - Topic") || channel.hasSuffix("VEVO") { return true }
        guard let json = try? await YouTubeAPI.post("player", body: ["videoId": video.videoId]),
              let category = JSON.string("category", in: json["microformat"]) else { return nil }
        return category == "Music"
    }
}

extension Color {
    static let lime = Color(red: 0.48, green: 0.74, blue: 0.08)
    static let violet = Color(red: 0.55, green: 0.36, blue: 0.96)
}

/// Woof Music's shortcut tile: two fanned covers over a large symbol the corner crops.
struct ShortcutTile: View {
    let title: String
    let subtitle: String?
    let icon: String
    let tint: Color
    let covers: [String]

    private static let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            fannedCovers
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2.weight(.semibold))
                        .opacity(0.85)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .frame(height: 116)
        .background {
            ZStack {
                LinearGradient(colors: [tint, tint.mix(with: .black, by: 0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
                LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .top, endPoint: .center)
                Image(systemName: icon)
                    .font(.system(size: 66, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
                    .rotationEffect(.degrees(-18))
                    .offset(x: 19, y: 9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
            .clipShape(Self.shape)
            .shadow(color: tint.opacity(0.4), radius: 6, y: 4)
            .accessibilityHidden(true)
        }
        .contentShape(Self.shape)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var fannedCovers: some View {
        if let first = covers.first {
            ZStack(alignment: .topLeading) {
                if covers.count > 1 {
                    cover(covers[1])
                        .rotationEffect(.degrees(-8))
                        .offset(x: 2, y: 8)
                }
                cover(first)
                    .rotationEffect(.degrees(covers.count > 1 ? 6 : 0))
                    .offset(x: covers.count > 1 ? 24 : 2, y: 2)
            }
        }
    }

    private func cover(_ url: String) -> some View {
        CoverImage(url: url)
            .frame(width: 56, height: 32)
            .clipShape(.rect(cornerRadius: Layout.rowPadding, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
    }
}

/// Woof Music's playlist page: header card over the blurred cover, then compact rows.
struct PlaylistPage: View {
    let title: String
    let playlistId: String

    @Environment(Router.self) private var router
    @State private var model = FeedModel()
    @State private var newTitle: String?
    @State private var isRenaming = false
    @State private var draftTitle = ""

    private var shownTitle: String { newTitle ?? title }
    /// Liked Videos follows your likes, so it can't be edited like a playlist.
    private var allowsRemoving: Bool { playlistId != YouTubeFeeds.likedVideosPlaylistId }
    private var allowsRenaming: Bool { allowsRemoving && playlistId != YouTubeFeeds.watchLaterPlaylistId }

    private var videos: [YouTubeVideo] { model.rowVideos }

    private var meta: String {
        guard !videos.isEmpty else { return "Playlist" }
        let total = videos.compactMap(\.durationSeconds).reduce(0, +)
        let count = "\(videos.count)\(model.hasMore ? "+" : "") \(videos.count == 1 ? "video" : "videos")"
        return total > 0 ? count + " · " + Double(total).clockText : count
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                if videos.isEmpty, model.isLoading {
                    LoadingRows(kind: .compact)
                }
                if videos.isEmpty, !model.isLoading {
                    ContentUnavailableView {
                        Label(model.errorText == nil ? "No Videos" : "Couldn't Load", systemImage: "play.rectangle")
                    } description: {
                        if let errorText = model.errorText { Text(errorText) }
                    }
                }
                FeedRows(model: model, isCompact: true, editablePlaylistId: allowsRemoving ? playlistId : nil, playlistTitle: shownTitle)
                    .environment(\.playlistVideos, videos)
            }
        }
        .toolbar {
            Menu("Options", systemImage: "ellipsis") {
                Button("Download", systemImage: "arrow.down.to.line") {
                    Task {
                        DownloadStore.shared.download(await FeedModel.allVideos(ofPlaylist: playlistId), maxHeight: router.maxHeight)
                    }
                }
                if allowsRenaming {
                    Button("Rename", systemImage: "pencil") {
                        draftTitle = shownTitle
                        isRenaming = true
                    }
                }
            }
        }
        .alert("Rename Playlist", isPresented: $isRenaming) {
            TextField("Title", text: $draftTitle)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let name = draftTitle
                newTitle = name
                router.run {
                    _ = try await InnerTubeClient.woofplay.editPlaylist(
                        playlistId: playlistId,
                        actions: [["action": "ACTION_SET_PLAYLIST_NAME", "playlistName": name]]
                    )
                }
            }
        }
        .detailBarTitle(shownTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .tappingRefresh { await load() }
        .task {
            if model.items.isEmpty { await load() }
        }
    }

    private func load() async {
        await model.load(.browse(YouTubeFeeds.playlistBrowseId(playlistId)))
    }

    private var header: some View {
        VideoListHeader(meta: meta, title: shownTitle, cover: videos.first?.thumbnailURL, videos: videos) {
            if let first = videos.first {
                router.playPlaylist(first, title: shownTitle, model: model)
            }
        }
    }
}

/// A Twitch channel among the YouTube ones: the same row, with LIVE on the picture while it streams.
private struct TwitchFollowRow: View {
    let follow: TwitchFollow

    var body: some View {
        HStack(spacing: Layout.menuRowSpacing) {
            Avatar(url: follow.avatar, size: Layout.avatarMedium)
                .overlay(alignment: .bottom) {
                    if follow.live != nil {
                        Text("LIVE")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, Layout.cardSpacing + 1)
                            .background(.tint, in: .capsule)
                            .offset(y: Layout.rowPadding)
                    }
                }
            VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                Text(follow.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(follow.live.map { [$0.game, "Twitch"].filter { !$0.isEmpty }.joined(separator: " · ") } ?? "Twitch")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// A playlist in Library's grid, as in Woof Music: the cover with two cards stacked behind it,
/// the title on two lines and the video count.
private struct PlaylistGridCell: View {
    let url: String?
    let title: String
    let subtitle: String?
    /// How far each card behind the cover peeks out, and how much narrower it is.
    private static let step: CGFloat = 4
    private static let inset: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.cardSpacing) {
            CoverImage(url: url)
                .aspectRatio(Layout.videoAspect, contentMode: .fit)
                .clipShape(.rect(cornerRadius: Layout.tileRadius, style: .continuous))
                .zoomLinkCover()
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: Layout.tileRadius, style: .continuous)
                            .fill(Color(.systemGray4))
                            .padding(.horizontal, Self.inset * 2)
                            .offset(y: -2 * Self.step)
                        RoundedRectangle(cornerRadius: Layout.tileRadius, style: .continuous)
                            .fill(Color(.systemGray2))
                            .padding(.horizontal, Self.inset)
                            .offset(y: -Self.step)
                    }
                    .accessibilityHidden(true)
                }
                .padding(.top, Self.step * 2)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}

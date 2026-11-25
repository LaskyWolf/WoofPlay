import SwiftUI
import SwiftyTube
import WebKit

/// Twitch's sign-in, as Add Account's Twitch step: the app the user registered, then the code
/// they confirm on Twitch. A Client ID saved before skips the first step.
struct TwitchSignInView: View {
    @ObservedObject private var account = TwitchAccount.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var code: TwitchAccount.DeviceCode?
    @State private var error: String?
    @State private var isWorking = false
    @State private var editsClientId = false
    @State private var copied = 0

    private static let console = URL(string: "https://dev.twitch.tv/console/apps/create")!

    private var needsClientId: Bool { account.clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editsClientId }

    var body: some View {
        NavigationStack {
            Form {
                if needsClientId {
                    appStep
                } else {
                    codeStep
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add Twitch Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sensoryFeedback(.success, trigger: copied)
            .task(id: code?.deviceCode) {
                guard let code else { return }
                do {
                    try await account.waitForApproval(of: code)
                    await TwitchLive.shared.refresh(force: true)
                    dismiss()
                } catch is CancellationError {
                } catch {
                    self.error = error.localizedDescription
                    self.code = nil
                }
            }
        }
    }

    /// Twitch only signs in apps it knows, so the user registers one once and pastes its ID.
    private var appStep: some View {
        Section {
            stepRow(1, "Open the Twitch developer console and register an app.")
            stepRow(2, "Set the OAuth Redirect URL to https://localhost and the client type to Public.")
            stepRow(3, "Copy the app's Client ID and paste it below.")
            Button("Open Developer Console", systemImage: "arrow.up.forward.app") { openURL(Self.console) }
            TextField("Client ID", text: $account.clientId)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
            Button("Continue") {
                editsClientId = false
                start()
            }
            .disabled(account.clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: {
            Text("Your Twitch App")
        } footer: {
            Text("Done once. The ID stays on this iPhone for the next sign-in.")
        }
    }

    private var codeStep: some View {
        Section {
            if let code {
                Text(code.userCode)
                    .font(.largeTitle.monospaced().weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .textSelection(.enabled)
                    .padding(.vertical, Layout.chipSpacing)
                Button("Copy Code and Open Twitch", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = code.userCode
                    copied += 1
                    if let url = URL(string: code.verificationUri) { openURL(url) }
                }
                HStack(spacing: Layout.chipSpacing) {
                    ProgressView()
                    Text("Waiting for Twitch…").foregroundStyle(.secondary)
                }
            } else if error != nil, !isWorking {
                Button("Try Again", systemImage: "arrow.clockwise") { start() }
            } else {
                HStack(spacing: Layout.chipSpacing) {
                    ProgressView()
                    Text("Getting a code…").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Confirm on Twitch")
        } footer: {
            VStack(alignment: .leading, spacing: Layout.chipSpacing) {
                Text("Sign in on Twitch and confirm this code. This page closes by itself when Twitch says yes.")
                Button("Use Another Client ID") {
                    code = nil
                    editsClientId = true
                }
                .font(.footnote.weight(.semibold))
            }
        }
        .task { if code == nil, !isWorking { start() } }
    }

    private func stepRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Layout.rowSpacing) {
            Text("\(number)")
                .font(.footnote.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(.tint, in: .circle)
            Text(text).font(.subheadline)
        }
    }

    private func start() {
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                code = try await account.requestCode()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// The part of the player page under a Twitch stream: what's on, who's streaming, and the chat.
struct TwitchWatchDetails: View {
    let video: YouTubeVideo
    @Environment(Router.self) private var router
    @ObservedObject private var live = TwitchLive.shared
    @State private var channel: TwitchChannel?
    @State private var youTubeChannelId: String?
    @State private var showsChat = false
    @State private var showsBio = false
    /// Started with the page, so the chat is already full when it opens.
    @StateObject private var chat = LiveChatModel()
    /// Twitch's own page for following or subscribing, inside the app.
    @State private var twitchPage: TwitchPage?
    /// Twitch updates the viewer count about once a minute.
    private static let refresh = Duration.seconds(60)
    /// The height of YouTube's action row, so both pages line up.
    private static let actionHeight: CGFloat = 38

    private var login: String { video.twitchLogin ?? "" }
    private var page: URL? { URL(string: "https://www.twitch.tv/\(login)") }
    /// YouTube videos: your Home recommendations, or else videos about what's being streamed.
    @State private var videos = FeedModel()

    private var upNextStreams: [TwitchChannel] {
        (live.channels + live.suggested).filter { $0.login != login }
    }

    private var upNextVideos: [YouTubeVideo] {
        Array(videos.videosAndShorts.prefix(Self.videosShown))
    }

    private static let videosShown = 12

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            Text(channel?.title ?? video.title)
                .font(.title3.bold())
                .fixedSize(horizontal: false, vertical: true)
            channelRow
            actions
            PlaybackFailure(player: router.player)
            descriptionCard
            LiveChatButton(showsChat: $showsChat)
            if !upNextStreams.isEmpty || !upNextVideos.isEmpty {
                Text("Up Next")
                    .font(.title3.bold())
                    .padding(.top, Layout.chipSpacing)
                UpNextList(videos: upNextVideos, streams: upNextStreams)
            }
        }
        .padding(Layout.screenPadding)
        .sheet(isPresented: $showsChat) { LiveChatSheet(model: chat) }
        .sheet(item: $twitchPage, onDismiss: { Task { await live.refresh(force: true) } }) { page in
            TwitchPageSheet(page: page)
        }
        .task(id: login) {
            chat.reset()
            await chat.run(.twitch(login: login))
        }
        .task(id: login) {
            youTubeChannelId = await Twitch.youTubeChannel(of: login)
            // Your Home recommendations, as Up Next under a YouTube video would show.
            await videos.load(.browse(YouTubeFeeds.home))
            // Signed out or empty: videos about what's being streamed.
            if videos.videosAndShorts.isEmpty {
                if channel == nil { channel = try? await Twitch.channel(login) }
                if let game = channel?.game, !game.isEmpty { await videos.load(.search(game)) }
            }
        }
        .task(id: login) {
            await live.refresh()
            while !Task.isCancelled {
                if let fresh = try? await Twitch.channel(login) { channel = fresh }
                try? await Task.sleep(for: Self.refresh)
            }
        }
    }

    /// The streamer, and their YouTube channel when the Twitch channel links one.
    private var channelRow: some View {
        HStack(spacing: Layout.rowSpacing) {
            Button {
                if let youTubeChannelId { router.openChannelPage(youTubeChannelId) }
            } label: {
                HStack(spacing: Layout.rowSpacing) {
                    Avatar(url: channel?.avatar ?? video.channelAvatarURL, size: Layout.avatarSmall)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(channel?.name ?? video.channelTitle ?? login)
                            .font(.subheadline.weight(.semibold))
                        Text(channel.map { "\($0.viewers.formatted()) watching" } ?? video.viewCountText ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(ZoomPressStyle(scale: 0.98))
            .disabled(youTubeChannelId == nil)
            Spacer(minLength: 0)
            // Twitch's API can't follow for another app, so this opens Twitch's own page in a sheet.
            if let page {
                FollowButton(isFollowing: isFollowing) { twitchPage = TwitchPage(url: page) }
            }
        }
    }

    /// Live followed channels hold this one when you follow it, since the page only shows live streams.
    private var isFollowing: Bool { live.channels.contains { $0.login == login } }

    /// Twitch's API can't subscribe for another app, so this opens Twitch's own page in a sheet.
    private var actions: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: Layout.chipSpacing) {
                actionButton("Subscribe", systemImage: "star", url: URL(string: "https://www.twitch.tv/subs/\(login)"))
                if let page {
                    ShareLink(item: page) { HeaderRoundIcon(systemImage: "square.and.arrow.up") }
                        .accessibilityLabel("Share")
                }
            }
            .buttonStyle(GlassPressStyle())
        }
    }

    private func actionButton(_ title: String, systemImage: String, url: URL?) -> some View {
        Button {
            if let url { twitchPage = TwitchPage(url: url) }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: Self.actionHeight)
                .glassEffect(.regular.interactive(), in: .capsule)
                .contentShape(Rectangle().inset(by: -3))
        }
        .accessibilityHint("Opens Twitch in the app")
    }

    /// Like a video's description: the category on top, then the channel's About text.
    private var descriptionCard: some View {
        Button {
            withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .snappy) { showsBio.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                Text([channel?.game, "Live"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline.weight(.semibold))
                if let bio = channel?.bio {
                    Text(bio)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(showsBio ? nil : 2)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .materialCard()
        }
        .buttonStyle(ZoomPressStyle(scale: 0.98))
        .disabled(channel?.bio == nil)
    }
}

/// A live Twitch stream among the videos of a feed: the video card, with LIVE under a ringed picture
/// and the viewer count where the duration goes.
/// A live Twitch stream as the same card as a YouTube video, so live streams from both look alike.
struct TwitchStreamRow: View {
    let channel: TwitchChannel
    @Environment(Router.self) private var router
    @ObservedObject private var live = TwitchLive.shared

    private var isFollowed: Bool { live.channels.contains { $0.login == channel.login } }

    var body: some View {
        VideoRow(video: channel.video, extras: VideoExtras(isSuggestedStream: !isFollowed)) {
            router.openVideo(channel.video)
        }
    }
}

/// "Ad · N s" over the picture while Twitch plays an ad. The ad itself is taken out, so the picture waits.
struct TwitchAdBadge: View {
    @ObservedObject var stream: TwitchStream

    var body: some View {
        if stream.isAd {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(label(at: context.date))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, Layout.rowSpacing)
                    .padding(.vertical, Layout.chipSpacing)
                    .background(.black.opacity(0.6), in: .capsule)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, Layout.rowSpacing)
            .allowsHitTesting(false)
            .accessibilityLabel("Twitch is playing an ad. The stream comes back after it.")
        }
    }

    private func label(at now: Date) -> String {
        guard let end = stream.adEnds else { return "Ad" }
        return "Ad · \(max(Int(end.timeIntervalSince(now).rounded(.up)), 0)) s"
    }
}

/// A Twitch creator's page in the app: the stream when they're live, otherwise their last one, and their About text.
struct TwitchCreatorPage: View {
    let login: String
    let name: String
    let avatar: String?
    @State private var isFollowing: Bool?
    @State private var twitchPage: TwitchPage?
    @State private var profile: Twitch.Profile?
    @State private var errorText: String?

    private var page: URL? { URL(string: "https://www.twitch.tv/\(login)") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let live = profile?.live {
                    SectionTitle(title: "Live on Twitch")
                    TwitchStreamRow(channel: live)
                        .padding(.horizontal, Layout.screenPadding)
                } else if let profile {
                    SectionTitle(title: "Offline")
                    lastBroadcast(profile)
                        .padding(.horizontal, Layout.screenPadding)
                } else if let errorText {
                    ContentUnavailableView("Couldn't Load", systemImage: "wifi.exclamationmark", description: Text(errorText))
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, Layout.sectionSpacing)
                }
                if let clips = profile?.clips, !clips.isEmpty {
                    TwitchShelf(title: "Popular Clips", videos: clips)
                }
                if let broadcasts = profile?.broadcasts, !broadcasts.isEmpty {
                    TwitchShelf(title: "Past Broadcasts", videos: broadcasts)
                }
                if let bio = profile?.bio {
                    SectionTitle(title: "About")
                    Text(bio)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Layout.screenPadding)
                }
            }
            .padding(.bottom, Layout.sectionSpacing)
        }
        .detailBarTitle(profile?.name ?? name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task(id: login) { await load() }
        .refreshable { await load() }
        .sheet(item: $twitchPage, onDismiss: { Task { await load() } }) { page in
            TwitchPageSheet(page: page)
        }
    }

    private func load() async {
        do {
            profile = try await Twitch.profile(login)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
        isFollowing = await TwitchAccount.shared.isFollowing(login)
    }

    private var header: some View {
        let picture = profile?.avatar ?? avatar
        return DetailHeaderCard(meta: "Twitch", title: profile?.name ?? name, artSize: Layout.avatarLarge) {
            CoverImage(url: picture)
                .clipShape(.circle)
                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 3))
        } secondary: {
            if let followers = profile?.followers {
                Text("\(followers.compactText) \(followers == 1 ? "follower" : "followers")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } buttons: {
            if let page {
                // Twitch's API can't follow for another app, so this opens Twitch's own page in a sheet.
                if let isFollowing {
                    FollowButton(isFollowing: isFollowing, isLarge: true) { twitchPage = TwitchPage(url: page) }
                }
                Button { twitchPage = TwitchPage(url: page) } label: {
                    HeaderRoundIcon(systemImage: "arrow.up.forward.app")
                }
                .accessibilityLabel("Open on Twitch")
            }
        }
        .padding(.vertical, Layout.screenPadding)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) { BlurredArtworkBackdrop(url: profile?.banner ?? picture) }
    }

    /// What they streamed last, since Twitch's past broadcasts don't play here.
    private func lastBroadcast(_ profile: Twitch.Profile) -> some View {
        VStack(alignment: .leading, spacing: Layout.cardSpacing) {
            if let title = profile.lastTitle {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
            }
            let facts = [profile.lastGame, profile.lastStarted.map { "Last live " + $0.formatted(.relative(presentation: .named)) }]
                .compactMap { $0 }
                .joined(separator: " · ")
            Text(facts.isEmpty ? "\(profile.name) isn't live right now." : facts)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Layout.rowSpacing)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: Layout.cardRadius, style: .continuous))
    }
}

struct TwitchPage: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Twitch's website in a sheet. The default website data store keeps the sign-in, so you sign in to Twitch here once.
struct TwitchPageSheet: View {
    let page: TwitchPage

    var body: some View {
        NavigationStack {
            TwitchWebView(url: page.url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Twitch")
                .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDragIndicator(.visible)
    }
}

private struct TwitchWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}

/// Under a Twitch past broadcast or clip: what it is and whose. Twitch sends no comments or likes for these here.
struct TwitchMediaDetails: View {
    let video: YouTubeVideo

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            Text(video.title)
                .font(.title3.bold())
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Layout.rowSpacing) {
                Avatar(url: video.channelAvatarURL, size: Layout.avatarSmall)
                VStack(alignment: .leading, spacing: 2) {
                    Text(video.channelTitle ?? "Twitch")
                        .font(.subheadline.weight(.semibold))
                    Text([video.viewCountText, video.publishedTimeText].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Layout.screenPadding)
    }
}

/// A sideways row of clips or past broadcasts. No long-press menu: its actions are YouTube's.
private struct TwitchShelf: View {
    let title: String
    let videos: [YouTubeVideo]
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Layout.rowSpacing) {
                    ForEach(videos, id: \.videoId) { video in
                        VideoRow(video: video, isNarrow: true) { router.openVideo(video) }
                            .frame(width: Layout.videoMedium)
                    }
                }
                .padding(.horizontal, Layout.screenPadding)
            }
        }
    }
}

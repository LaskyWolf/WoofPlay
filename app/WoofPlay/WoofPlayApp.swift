import SwiftUI
import SwiftyTube

extension InnerTubeClient {
    static let woofplay = InnerTubeClient(config: .youtube)
}

@main
struct WoofPlayApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = Session()
    @State private var router = Router()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            AppearanceRoot {
                if session.isSignedIn {
                    // A new identity resets every tab's feeds when the account changes.
                    RootTabs().id(session.generation)
                } else if session.isRestoring {
                    Color(.systemBackground).ignoresSafeArea()
                } else {
                    SignInView()
                }
            }
            .environmentObject(session)
            .environment(router)
            .environmentObject(settings)
            .onOpenURL { router.receive($0) }
            .task {
                SwiftyTubeLog.handler = { message, level in
                    if level == .error { FileLog.shared.append("swiftytube", "ERROR", message) }
                }
                await InnerTubeClient.woofplay.updateLocale(YouTubeLocale(
                    gl: Locale.current.region?.identifier ?? "US",
                    hl: Locale.current.language.languageCode?.identifier ?? "en"
                ))
                await session.restore()
                #if DEBUG
                await StreamCache.selfCheck()
                CoverTint.selfCheck()
                Orientation.selfCheck()
                TVLink.selfCheck()
                LTEnvelope.selfCheck()
                GlyphScript.selfCheck()
                WatchSegments.selfCheck()
                EndScreenElement.selfCheck()
                WatchedChannels.selfCheck()
                YouTubeAPI.selfCheck()
                SponsorBlock.selfCheck()
                LockupDetails.selfCheck()
                FeedParser.selfCheck()
                DeArrow.selfCheck()
                DiagnosticsSection.selfCheck()
                CommentsPage.selfCheck()
                VideoFlavor.selfCheck()
                YouTubeLink.selfCheck()
                StreamLoader.selfCheck()
                AppUpdate.selfCheck()
                Twitch.selfCheck()
                TwitchAdFilter.selfCheck()
                LiveChatModel.selfCheck()
                IRCLine.selfCheck()
                UMP.selfCheck()
                ChannelBell.selfCheck()
                #endif
            }
            .alert("Session Expired", isPresented: $session.isExpired) {
                Button("Sign In Again") {
                    router.close()
                    Task { await session.signOut() }
                }
                Button("Not Now", role: .cancel) {}
            } message: {
                Text("Google no longer accepts this sign-in. Your feeds won't be personal until you sign in again.")
            }
        }
    }
}

/// A view, so a new accent or theme applies straight away. The window's tint
/// colours what UIKit draws for SwiftUI, such as the icons in menus and alerts.
private struct AppearanceRoot<Content: View>: View {
    @ViewBuilder let content: Content
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        content
            .tint(settings.accentColor)
            .preferredColorScheme(settings.themeMode.colorScheme)
            .onAppear(perform: applyWindowTint)
            .onChange(of: settings.accentName) { applyWindowTint() }
    }

    private func applyWindowTint() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.windows.forEach { $0.tintColor = UIColor(settings.accentColor) }
        }
    }
}

extension View {
    /// Channels and errors. Only the top screen can present them, so the
    /// tabs and the video page each attach these and the tabs stand down while it's open.
    func routerPresentations(_ router: Router, isActive: Bool) -> some View {
        sheet(item: Binding(get: { isActive ? router.channelRoute : nil }, set: { router.channelRoute = $0 })) { route in
            NavigationStack {
                ChannelView(channelId: route.id)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { router.channelRoute = nil }
                        }
                    }
            }
            .presentationDragIndicator(.visible)
        }
        .sheet(item: Binding(get: { isActive ? router.hashtagRoute : nil }, set: { router.hashtagRoute = $0 })) { route in
            NavigationStack {
                HashtagPage(tag: route.tag)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { router.hashtagRoute = nil }
                        }
                    }
            }
            .presentationDragIndicator(.visible)
        }
        .alert("That Didn't Work", isPresented: Binding(get: { isActive && router.actionMessage != nil }, set: { if !$0 { router.actionMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(router.actionMessage ?? "")
        }
        .alert("Torrent Started", isPresented: Binding(get: { isActive && router.torrentNotice != nil }, set: { if !$0 { router.torrentNotice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(router.torrentNotice ?? "")
        }
    }
}

enum AppTab: String, Hashable {
    // The raw values are saved as the start tab, so they keep their old names.
    case home = "Home", library = "Library", subs = "Subs", search = "Search"

    var title: String {
        switch self {
        case .home: "Explore"
        case .library: "Library"
        case .subs: "Following"
        case .search: "Search"
        }
    }

    /// The tabs the app can open on.
    static let startTabs: [AppTab] = [.home, .library, .subs]
}

/// The pages a tab opens from code.
struct TabDestinations: ViewModifier {
    let tab: AppTab
    @Environment(Router.self) private var router

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: HeaderRoute.self) { route in
                Group {
                    switch route {
                    case .notifications: NotificationsView()
                    case .history: ScopedSearchPage(title: "History", prompt: "Search your history", browseId: YouTubeFeeds.history)
                    case .settings: SettingsView()
                    }
                }
            }
            .navigationDestination(item: Binding(get: { router.channelPage?.tab == tab ? router.channelPage : nil }, set: { router.channelPage = $0 })) { route in
                ChannelView(channelId: route.id)
                    .id(route.id)
            }
    }
}

/// Haptics for things that finish or fail while the person may be looking elsewhere.
/// The types are spelled out: left to infer them, the compiler gives up on this chain.
private struct ResultFeedback: ViewModifier {
    @Environment(Router.self) private var router
    @ObservedObject private var downloads = DownloadStore.shared

    private var completed: Int { downloads.batch?.completed ?? 0 }
    private var failed: Int { downloads.batch?.failed ?? 0 }
    private var hasError: Bool { router.loadError != nil || router.actionMessage != nil }

    private static func grew(_ old: Int, _ new: Int) -> Bool { new > old }
    private static func appeared(_ old: Bool, _ new: Bool) -> Bool { new }

    func body(content: Content) -> some View {
        content
            .sensoryFeedback(SensoryFeedback.success, trigger: completed, condition: Self.grew)
            .sensoryFeedback(SensoryFeedback.error, trigger: failed, condition: Self.grew)
            .sensoryFeedback(SensoryFeedback.error, trigger: hasError, condition: Self.appeared)
    }
}

struct RootTabs: View {
    @Environment(Router.self) private var router
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    /// Links the floating card and the video page for the zoom, as Woof Music does for its player.
    @Namespace private var playerZoom

    var body: some View {
        players
            .routerPresentations(router, isActive: !router.isExpanded)
            .task { await Subscriptions.shared.load() }
            .task { await AppUpdate.shared.check() }
            // Waits here because a link can arrive while the app is still restoring the sign-in.
            .task(id: router.pendingLink) {
                guard let link = router.pendingLink else { return }
                router.pendingLink = nil
                router.open(link)
            }
            .onChange(of: scenePhase) {
                router.sceneChanged(isBackground: scenePhase == .background)
                if scenePhase == .active { router.sceneBecameActive() }
            }
    }

    /// Split from `body` so each part type-checks on its own: the whole chain at once is too slow for the compiler.
    private var tabs: some View {
        TabView(selection: Bindable(router).selectedTab) {
            // Right-to-left puts the first tab on the right, so the left-handed bar lists them
            // backwards: on screen they stay Home, Library, Subs, with Search moved to the left.
            if settings.leftHandedTabBar {
                subsTab
                libraryTab
                homeTab
            } else {
                homeTab
                libraryTab
                subsTab
            }
            Tab(value: AppTab.search, role: .search) {
                SearchScreen().environment(\.layoutDirection, .leftToRight)
            }
        }
        .environment(\.layoutDirection, settings.leftHandedTabBar ? .rightToLeft : .leftToRight)
        .tabBarMinimizeBehavior(.onScrollDown)
        // Selecting Search activates it, and its X goes back to the previous tab.
        .tabViewSearchActivation(.searchTabSelection)
        .modifier(ResultFeedback())
    }

    // Each page is set back to left-to-right; only the tab bar flips.
    private var homeTab: some TabContent<AppTab> {
        Tab(AppTab.home.title, systemImage: "safari", value: AppTab.home) {
            HomeView().environment(\.layoutDirection, .leftToRight)
        }
    }

    private var libraryTab: some TabContent<AppTab> {
        Tab(AppTab.library.title, systemImage: "play.square.stack", value: AppTab.library) {
            LibraryView().environment(\.layoutDirection, .leftToRight)
        }
    }

    private var subsTab: some TabContent<AppTab> {
        Tab(AppTab.subs.title, systemImage: "rectangle.stack.badge.play", value: AppTab.subs) {
            SubsView().environment(\.layoutDirection, .leftToRight)
        }
    }

    private var players: some View {
        tabs
            .environment(\.videoZoomSpace, playerZoom)
            .overlay { PlayerOverlay(zoom: playerZoom) }
            .fullScreenCover(isPresented: Bindable(router).isExpanded) {
                WatchPage()
                    .navigationTransition(.zoom(sourceID: router.zoomSource, in: playerZoom))
                    .presentationBackground(.clear)
                    .onAppear { router.isWatchPageOnScreen = true }
                    .onDisappear { router.isWatchPageOnScreen = false }
            }
            .fullScreenCover(item: Bindable(router).shortsRoute) { route in
                ShortsView(model: route.model)
                    .navigationTransition(.zoom(sourceID: router.zoomSource, in: playerZoom))
                    .presentationBackground(.clear)
                    .onAppear { router.isShortsPageOnScreen = true }
                    .onDisappear { router.isShortsPageOnScreen = false }
            }
    }
}

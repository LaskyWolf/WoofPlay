import SwiftUI
import SwiftyTube

/// The same presets as Woof Music's SettingsStore.
struct AccentPreset: Identifiable, Hashable {
    let name: String
    let color: Color
    var id: String { name }

    /// The icons in "App Icons" are named after the accent. The main icon is Default Blue.
    var alternateIconName: String? {
        name == AccentPreset.all[0].name ? nil : name
    }

    static let all: [AccentPreset] = [
        AccentPreset(name: "Default Blue", color: Color(red: 0, green: 0.48, blue: 1)),
        AccentPreset(name: "Red", color: Color(red: 0.91, green: 0.22, blue: 0.22)),
        AccentPreset(name: "Orange", color: Color(red: 0.95, green: 0.45, blue: 0.13)),
        AccentPreset(name: "Amber", color: Color(red: 0.98, green: 0.70, blue: 0.15)),
        AccentPreset(name: "Green", color: Color(red: 0.18, green: 0.72, blue: 0.32)),
        AccentPreset(name: "Teal", color: Color(red: 0.12, green: 0.65, blue: 0.60)),
        AccentPreset(name: "Cyan", color: Color(red: 0.15, green: 0.70, blue: 0.90)),
        AccentPreset(name: "Purple", color: Color(red: 0.60, green: 0.35, blue: 0.90)),
        AccentPreset(name: "Pink", color: Color(red: 0.94, green: 0.35, blue: 0.66)),
        AccentPreset(name: "Indigo", color: Color(red: 0.33, green: 0.40, blue: 0.95)),
        AccentPreset(name: "Lime", color: Color(red: 0.55, green: 0.75, blue: 0.20)),
        AccentPreset(name: "Brown", color: Color(red: 0.62, green: 0.43, blue: 0.30))
    ]
}

enum ThemeMode: String, CaseIterable, Identifiable {
    case system = "System", light = "Light", dark = "Dark"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Library's playlists, as rows or as covers in two columns, as in Woof Music.
enum LibraryLayout: String, CaseIterable, Identifiable {
    case list = "List", grid = "Grid"
    var id: Self { self }
    var symbol: String { self == .list ? "list.bullet" : "square.grid.2x2" }
}

final class AppSettings: ObservableObject {
    private static let accentKey = "settings.accentName"
    private static let themeKey = "settings.themeMode"
    private static let libraryLayoutKey = "settings.libraryLayout"
    private static let startTabKey = "settings.startTab"
    private static let leftHandedKey = "settings.leftHandedTabBar"

    @Published var accentName: String {
        didSet { UserDefaults.standard.set(accentName, forKey: Self.accentKey) }
    }
    @Published var themeMode: ThemeMode {
        didSet { UserDefaults.standard.set(themeMode.rawValue, forKey: Self.themeKey) }
    }

    @Published var libraryLayout: LibraryLayout {
        didSet { UserDefaults.standard.set(libraryLayout.rawValue, forKey: Self.libraryLayoutKey) }
    }
    @Published var startTab: AppTab {
        didSet { UserDefaults.standard.set(startTab.rawValue, forKey: Self.startTabKey) }
    }
    /// Search on the left of the tab bar, nearer a left thumb.
    @Published var leftHandedTabBar: Bool {
        didSet { UserDefaults.standard.set(leftHandedTabBar, forKey: Self.leftHandedKey) }
    }

    /// Read before the settings object exists, for the tab the app opens on.
    static var savedStartTab: AppTab {
        UserDefaults.standard.string(forKey: startTabKey).flatMap(AppTab.init(rawValue:)) ?? .home
    }

    var accentColor: Color {
        AccentPreset.all.first { $0.name == accentName }?.color ?? AccentPreset.all[0].color
    }

    init() {
        let defaults = UserDefaults.standard
        accentName = defaults.string(forKey: Self.accentKey) ?? AccentPreset.all[0].name
        themeMode = ThemeMode(rawValue: defaults.string(forKey: Self.themeKey) ?? "") ?? .system
        libraryLayout = LibraryLayout(rawValue: defaults.string(forKey: Self.libraryLayoutKey) ?? "") ?? .list
        startTab = Self.savedStartTab
        leftHandedTabBar = defaults.bool(forKey: Self.leftHandedKey)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var session: Session
    @State private var showsDiagnostics = false

    var body: some View {
        List {
            Section {
                NavigationLink {
                    ProfileView()
                } label: {
                    HStack(spacing: Layout.menuRowSpacing) {
                        Avatar(url: session.account?.thumbnailUrl, size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.account?.name ?? "YouTube").font(.headline).lineLimit(1)
                            Text("YouTube").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if let release = AppUpdate.shared.available {
                            Spacer(minLength: 0)
                            Text("Update \(release.version)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                    .padding(.vertical, Layout.cardSpacing)
                }
                // Hidden: a long press opens Diagnostics.
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.8).onEnded { _ in showsDiagnostics = true })
                .sensoryFeedback(.impact(weight: .medium), trigger: showsDiagnostics) { _, isShown in isShown }
                .accessibilityAction(named: "Diagnostics") { showsDiagnostics = true }
            }
            Section("Appearance") {
                settingsRow("Appearance", icon: "paintpalette") { AppearanceSettingsView() }
            }
            Section("Playback") {
                settingsRow("Player", icon: "play.circle") { PlayerSettingsView() }
                settingsRow("Downloads", icon: "arrow.down.to.line") { DownloadSettingsView() }
            }
            Section("Privacy") {
                settingsRow("Privacy", icon: "hand.raised") { PrivacySettingsView() }
            }
            // Last, as in Woof Music.
            Section("Integrations") {
                settingsRow("Integrations", icon: "puzzlepiece.extension") { IntegrationsSettingsView() }
            }
        }
        .listSectionSpacing(.compact)
        .scrollBounceBehavior(.basedOnSize)
        .navigationDestination(isPresented: $showsDiagnostics) { DiagnosticsView() }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private func settingsRow<Destination: View>(_ title: String, icon: String, @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon).foregroundStyle(.tint)
            }
        }
    }
}

/// Woof Music's account page, with the accounts saved on this phone.
private struct ProfileView: View {
    @EnvironmentObject private var session: Session
    @Environment(Router.self) private var router
    @State private var confirmsSignOut = false
    @State private var choosesPlatform = false
    @State private var adding: AccountPlatform?
    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var twitch = TwitchAccount.shared
    @State private var twitchAvatar: String?
    @State private var isEditingPicture = false

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Button {
                        isEditingPicture = true
                    } label: {
                        Avatar(url: session.account?.thumbnailUrl, size: 96).overlay(alignment: .bottomTrailing) {
                            Image(systemName: "pencil")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.primary)
                                .frame(width: 32, height: 32)
                                .glassEffect(.regular, in: .circle)
                        }
                    }
                    .buttonStyle(ZoomPressStyle())
                    .accessibilityLabel("Change Profile Picture")
                    Text(session.account?.name ?? "YouTube").font(.title2.bold())
                    if let handle = session.account?.channelHandle {
                        Text(handle).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            if let email = session.account?.email {
                Section {
                    LabeledContent("Email", value: email)
                }
            }
            Section {
                ForEach(session.accounts) { saved in
                    Button {
                        guard saved.id != session.currentAccountId else { return }
                        router.close()
                        Task { await session.switchTo(saved) }
                    } label: {
                        HStack(spacing: Layout.rowSpacing) {
                            Avatar(url: saved.thumbnailUrl, size: 32)
                            Text(saved.name).foregroundStyle(.primary).lineLimit(1)
                            Spacer(minLength: 0)
                            if saved.id == session.currentAccountId {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .accessibilityAddTraits(saved.id == session.currentAccountId ? .isSelected : [])
                }
                // Shown only: Twitch holds one account, and Sign Out below removes it.
                if twitch.isSignedIn {
                    HStack(spacing: Layout.rowSpacing) {
                        Avatar(url: twitchAvatar, size: 32)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(twitch.login ?? "Signed In").lineLimit(1)
                            Text(AccountPlatform.twitch.rawValue).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                Button("Add Account", systemImage: "person.badge.plus") { choosesPlatform = true }
                    .confirmationDialog("Add an account from", isPresented: $choosesPlatform, titleVisibility: .visible) {
                        ForEach(AccountPlatform.allCases) { platform in
                            // Twitch holds one account at a time.
                            if platform != .twitch || !twitch.isSignedIn {
                                Button(platform.rawValue) { adding = platform }
                            }
                        }
                    }
            } header: {
                Text("Accounts")
            } footer: {
                Text(downloads.active.isEmpty
                    ? "Each account keeps its own downloads and watch progress on this iPhone."
                    : "You can change account when your downloads finish.")
            }
            .disabled(!downloads.active.isEmpty)
            Section {
                Button("Sign Out", role: .destructive) { confirmsSignOut = true }
                    .disabled(!downloads.active.isEmpty)
            }
            Section {
                LabeledContent("Version", value: "\(AppUpdate.currentVersion) (\(AppUpdate.currentBuild))")
                if let release = AppUpdate.shared.available {
                    Link(destination: release.page) {
                        Label("WoofTube \(release.version) Is Available", systemImage: "arrow.down.app")
                    }
                } else {
                    Button {
                        Task { await AppUpdate.shared.check() }
                    } label: {
                        HStack {
                            Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                            Spacer(minLength: Layout.chipSpacing)
                            if AppUpdate.shared.isChecking {
                                ProgressView()
                            } else if AppUpdate.shared.didCheck {
                                Text(AppUpdate.shared.errorText ?? "Up to Date")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(AppUpdate.shared.isChecking)
                }
            } header: {
                Text("App")
            } footer: {
                Text("Compares this version with the newest release on GitHub.")
            }
        }
        .listSectionSpacing(.compact)
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $adding) { platform in
            switch platform {
            case .youTube: AddAccountSheet()
            case .twitch: TwitchSignInView()
            }
        }
        .task(id: twitch.login) {
            await twitch.restore()
            if let login = twitch.login { twitchAvatar = await Twitch.avatars([login])[login] }
        }
        .sheet(isPresented: $isEditingPicture, onDismiss: { Task { await session.loadAccount() } }) {
            NavigationStack {
                ProfilePictureWebView()
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("YouTube Studio")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isEditingPicture = false }
                        }
                    }
            }
        }
        .confirmationDialog("Which account do you want to sign out of?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
            Button("\(session.account?.name ?? "YouTube") · YouTube", role: .destructive) {
                router.close()
                Task { await session.signOut() }
            }
            if twitch.isSignedIn {
                Button("\(twitch.login ?? "Twitch") · Twitch", role: .destructive) {
                    twitch.signOut()
                    TwitchLive.shared.clear()
                }
            }
        }
    }
}

/// The services an account can be added for. Another one is a case here and a sheet in `ProfileView`.
enum AccountPlatform: String, CaseIterable, Identifiable {
    case youTube = "YouTube"
    case twitch = "Twitch"

    var id: Self { self }
    var systemImage: String {
        switch self {
        case .youTube: "play.rectangle.fill"
        case .twitch: "dot.radiowaves.left.and.right"
        }
    }
}

private struct PlayerSettingsView: View {
    @Environment(Router.self) private var router
    var body: some View {
        List {
            Section {
                Picker(selection: Bindable(router).maxHeight) {
                    ForEach(Router.qualities, id: \.self) { Text("\($0)p").tag($0) }
                } label: {
                    Label {
                        Text("Maximum Quality")
                    } icon: {
                        Image(systemName: "sparkles.tv").glyphMotion(.qualitySparkle, trigger: router.maxHeight)
                    }
                }
                Toggle(isOn: Bindable(router).autoplay) {
                    Label {
                        Text("Autoplay")
                    } icon: {
                        Image(systemName: "play.square.stack").glyphMotion(router.autoplay ? .nextCard : .pop, trigger: router.autoplay)
                    }
                }
                Toggle("Picture in Picture", systemImage: "pip", isOn: Bindable(router).allowsPictureInPicture)
                Toggle("Stable Volume", systemImage: "speaker.wave.2", isOn: Bindable(router).stableVolume)
            } footer: {
                Text("Autoplay starts the first Up Next video when one ends. Picture in Picture keeps the video in a small window when you leave the app. Stable Volume evens out loud and quiet parts, so you don't have to keep changing the volume.")
            }
        }
        .navigationTitle("Player")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Services from outside YouTube. Each footer says what it receives.
private struct IntegrationsSettingsView: View {
    @Environment(Router.self) private var router
    @AppStorage(DislikeCounts.enabledKey) private var showsDislikeCounts = true
    @AppStorage(DeArrow.enabledKey) private var usesDeArrow = false

    var body: some View {
        List {
            Section {
                NavigationLink {
                    SponsorBlockSettingsView()
                } label: {
                    LabeledContent {
                        Text(router.usesSponsorBlock ? "On" : "Off")
                    } label: {
                        Label {
                            Text("SponsorBlock")
                        } icon: {
                            Image(systemName: "forward.end").glyphMotion(router.usesSponsorBlock ? .dashAhead : .pop, trigger: router.usesSponsorBlock)
                        }
                    }
                }
                NavigationLink(destination: WatchTogetherView()) {
                    Label {
                        Text("Watch Together")
                    } icon: {
                        Image(systemName: "person.2.wave.2").foregroundStyle(.tint)
                    }
                }
            }
            Section {
                Toggle("Community Titles", systemImage: "text.badge.checkmark", isOn: $usesDeArrow)
            } footer: {
                Text("Uses DeArrow's community titles and thumbnails in place of the originals. Its title list receives part of a code shared by many videos. Its thumbnail server receives the ID of each video with a new thumbnail, also in Incognito.")
            }
            Section {
                Toggle(isOn: $showsDislikeCounts) {
                    Label {
                        Text("Dislike Counts")
                    } icon: {
                        Image(systemName: "hand.thumbsdown").glyphMotion(showsDislikeCounts ? .dislike : .rise, trigger: showsDislikeCounts)
                    }
                }
            } footer: {
                Text("YouTube hides these numbers. They are estimates from Return YouTube Dislike, which receives the ID of each video you open or see in a feed.")
            }
            TVLinkSection()
        }
        .navigationTitle("Integrations")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// What this iPhone and YouTube keep of your searches and viewing.
private struct PrivacySettingsView: View {
    @AppStorage(SearchSettings.tracksHistoryKey) private var tracksSearchHistory = true
    @AppStorage(SearchSettings.tracksWatchHistoryKey) private var tracksWatchHistory = true

    var body: some View {
        List {
            Section {
                toggleRow("Track Search History", icon: "magnifyingglass", isOn: $tracksSearchHistory)
                toggleRow("Track Watch History", icon: "clock.arrow.circlepath", isOn: $tracksWatchHistory)
            } footer: {
                Text("When off, searches aren't saved, and videos you watch don't reach your YouTube history or this iPhone's resume points.")
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggleRow(_ title: String, icon: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon).foregroundStyle(.tint)
            }
        }
    }
}

private struct AppearanceSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 6)

    var body: some View {
        List {
            Section {
                Picker(selection: $settings.themeMode) {
                    ForEach(ThemeMode.allCases) { Text($0.rawValue).tag($0) }
                } label: {
                    Label {
                        Text("Theme Mode")
                    } icon: {
                        MorphingGlyph(systemName: settings.themeMode.symbol)
                            .glyphMotion(settings.themeMode == .dark ? .moonRise : .sunRise, trigger: settings.themeMode)
                    }
                }
            } header: {
                Text("Theme")
            } footer: {
                Text("Choose how the app follows your device appearance.")
            }

            Section {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(AccentPreset.all) { preset in
                        Button {
                            settings.accentName = preset.name
                            applyAppIcon(of: preset)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(preset.color)
                                    .frame(width: 34, height: 34)
                                if settings.accentName == preset.name {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                        }
                        .buttonStyle(ZoomPressStyle())
                        .accessibilityLabel(preset.name)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Accent Color")
            } footer: {
                Text("Applies to buttons, highlights, selected items, and the app icon.")
            }

            Section("Library") {
                Picker(selection: $settings.libraryLayout) {
                    ForEach(LibraryLayout.allCases) { Text($0.rawValue).tag($0) }
                } label: {
                    Label("Library Layout", systemImage: settings.libraryLayout.symbol)
                }
            }

            Section {
                Picker(selection: $settings.startTab) {
                    ForEach(AppTab.startTabs, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    Label("Start On", systemImage: "rectangle.portrait.on.rectangle.portrait")
                }
                Toggle(isOn: $settings.leftHandedTabBar) {
                    Label("Left-Handed Tab Bar", systemImage: "hand.point.left")
                }
            } header: {
                Text("General")
            } footer: {
                Text("Start On is the tab the app opens on. Left-Handed puts Search on the left, nearer your thumb; Home, Library and Subs keep their order.")
            }
        }
        .id(settings.accentName)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// iOS shows its own message when the icon changes.
    private func applyAppIcon(of preset: AccentPreset) {
        let application = UIApplication.shared
        guard application.supportsAlternateIcons, application.alternateIconName != preset.alternateIconName else { return }
        application.setAlternateIconName(preset.alternateIconName)
    }
}

/// Links a TV once with its code. The player's menu then offers to play there.
private struct TVLinkSection: View {
    @State private var code = ""
    @State private var isWorking = false
    @State private var errorText: String?
    private let link = TVLink.shared

    var body: some View {
        Section {
            if let screen = link.screen {
                LabeledContent {
                    Text(screen.name)
                } label: {
                    Label {
                        Text("TV")
                    } icon: {
                        Image(systemName: "tv").foregroundStyle(.tint)
                    }
                }
                Button("Forget \(screen.name)", role: .destructive) { link.forget() }
            } else {
                TextField("TV Code", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                Button {
                    pair()
                } label: {
                    HStack {
                        Text("Link TV")
                        Spacer(minLength: Layout.chipSpacing)
                        if isWorking { ProgressView() }
                    }
                }
                .disabled(code.filter(\.isNumber).isEmpty || isWorking)
            }
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("TV")
        } footer: {
            Text(link.screen == nil
                ? "In SmartTube, open Settings, then Remote Control. In YouTube on the TV, open Settings, then Link with TV Code."
                : "Play on TV appears in the player's menu. Open YouTube or SmartTube on the TV first.")
        }
    }

    private func pair() {
        isWorking = true
        errorText = nil
        Task {
            do {
                try await link.pair(code: code)
                code = ""
            } catch {
                errorText = error.localizedDescription
            }
            isWorking = false
        }
    }
}

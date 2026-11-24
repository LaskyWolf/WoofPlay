import Network
import SwiftUI
import SwiftyTube

/// Whether the phone can reach the internet. iOS doesn't tell apps about airplane mode itself,
/// so a dead zone and airplane mode look the same here, which is what the app needs.
@MainActor @Observable
final class Connectivity {
    static let shared = Connectivity()

    private(set) var isOffline = false

    private let monitor = NWPathMonitor()
    private var pending: Task<Void, Never>?

    /// A dropped connection often comes back within a second, while switching from Wi-Fi to cellular.
    private static let offlineDelay = Duration.seconds(1)

    private init() {
        monitor.pathUpdateHandler = { path in
            let isOnline = path.status == .satisfied
            Task { @MainActor in Connectivity.shared.update(isOnline: isOnline) }
        }
        monitor.start(queue: DispatchQueue(label: "com.laskywolf.woofplay.network"))
    }

    private func update(isOnline: Bool) {
        pending?.cancel()
        if isOnline {
            isOffline = false
            return
        }
        pending = Task {
            try? await Task.sleep(for: Self.offlineDelay)
            guard !Task.isCancelled else { return }
            isOffline = true
        }
    }
}

/// Takes the tab's title while offline: a pup asleep next to the word Offline, on a grey badge
/// that swells and settles with the pup's breath.
/// Where the header's buttons leave no room for the word on one line, the pup sleeps alone on it.
struct OfflineTitle: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathes = false

    /// How much the badge grows on each breath in.
    private static let breathScale = 1.035
    private static let radius: CGFloat = 16

    var body: some View {
        ViewThatFits(in: .horizontal) {
            badge {
                SleepingPup()
                Text("Offline")
                    .font(.title.weight(.heavy))
                    .lineLimit(1)
            }
            badge { SleepingPup() }
        }
        .scaleEffect(breathes ? Self.breathScale : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: SleepingPup.zCycle / 2).repeatForever(autoreverses: true)) { breathes = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Offline")
        .accessibilityAddTraits(.isHeader)
    }

    /// The grey of the filter chips, so the badge belongs to the app instead of looking like an alert.
    private func badge<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) { content() }
            .padding(.leading, 10)
            .padding(.trailing, 16)
            .padding(.vertical, 5)
            .background(Color(.systemGray5), in: .rect(cornerRadius: Self.radius, style: .continuous))
    }
}

/// The Woof apps' offline mark: a curled-up pup whose ear takes the app's accent, with z's floating up.
struct SleepingPup: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var breathes = false

    private static let size = CGSize(width: 64, height: 40)
    /// One z every this many seconds, three in the air at a time.
    static let zCycle = 3.2

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                draw(in: &context, scale: size.width / Self.size.width)
            }
            .scaleEffect(x: 1, y: breathes ? 1.06 : 1, anchor: .bottom)
            if reduceMotion {
                z(progress: 0.35)
            } else {
                TimelineView(.animation) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    ZStack(alignment: .topLeading) {
                        ForEach(0..<3, id: \.self) { index in
                            let phase = (time / Self.zCycle + Double(index) / 3).truncatingRemainder(dividingBy: 1)
                            z(progress: phase)
                        }
                    }
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: Self.zCycle / 2).repeatForever(autoreverses: true)) { breathes = true }
        }
    }

    /// A z rising from the pup's head: it grows, drifts right and fades.
    private func z(progress: Double) -> some View {
        let fadeIn = min(progress / 0.2, 1)
        return Text("z")
            .font(.system(size: 15, weight: .heavy, design: .rounded))
            .foregroundStyle(.tint)
            .scaleEffect(0.6 + 0.55 * progress)
            .opacity(fadeIn * (1 - progress))
            .offset(x: 25 + 14 * progress, y: -8 - 22 * progress)
    }

    private func draw(in context: inout GraphicsContext, scale: CGFloat) {
        context.scaleBy(x: scale, y: scale)
        let isDark = colorScheme == .dark
        let back = Color(white: isDark ? 0.9 : 0.8)
        let head = Color(white: isDark ? 0.95 : 0.87)
        let shade = Color(white: isDark ? 0.82 : 0.72)
        let ink = Color(white: 0.11)
        let accent = GraphicsContext.Shading.style(TintShapeStyle.tint)

        var body = Path()
        body.move(to: CGPoint(x: 16, y: 36))
        body.addCurve(to: CGPoint(x: 40, y: 14), control1: CGPoint(x: 16, y: 22), control2: CGPoint(x: 27, y: 14))
        body.addCurve(to: CGPoint(x: 60, y: 31), control1: CGPoint(x: 52, y: 14), control2: CGPoint(x: 60, y: 22))
        body.addCurve(to: CGPoint(x: 55, y: 36), control1: CGPoint(x: 60, y: 34), control2: CGPoint(x: 58, y: 36))
        body.closeSubpath()
        context.fill(body, with: .color(back))
        context.fill(Path(ellipseIn: CGRect(x: 42.5, y: 23.5, width: 13, height: 13)), with: .color(shade))

        var tail = Path()
        tail.move(to: CGPoint(x: 59, y: 29))
        tail.addCurve(to: CGPoint(x: 53, y: 36), control1: CGPoint(x: 62, y: 33), control2: CGPoint(x: 59, y: 37))
        context.stroke(tail, with: .color(back), style: StrokeStyle(lineWidth: 4, lineCap: .round))

        context.fill(Path(ellipseIn: CGRect(x: 11, y: 15, width: 20, height: 20)), with: .color(head))
        context.fill(Path(ellipseIn: CGRect(x: 3.5, y: 24.5, width: 15, height: 10)), with: .color(head))
        context.fill(Path(ellipseIn: CGRect(x: 2.5, y: 25.9, width: 4.2, height: 4.2)), with: .color(ink))

        var eye = Path()
        eye.move(to: CGPoint(x: 14, y: 23.5))
        eye.addQuadCurve(to: CGPoint(x: 18.6, y: 23.5), control: CGPoint(x: 16.3, y: 25.5))
        context.stroke(eye, with: .color(ink), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))

        var ear = Path()
        ear.move(to: CGPoint(x: 22, y: 15))
        ear.addCurve(to: CGPoint(x: 31, y: 27), control1: CGPoint(x: 30, y: 12), control2: CGPoint(x: 34, y: 19))
        ear.addCurve(to: CGPoint(x: 24, y: 27), control1: CGPoint(x: 29.5, y: 30.5), control2: CGPoint(x: 25, y: 30.5))
        ear.closeSubpath()
        context.fill(ear, with: accent)

        context.fill(Path(ellipseIn: CGRect(x: 10, y: 33.4, width: 14, height: 5.2)), with: .color(shade))
    }
}

/// Home while offline, the only page then, with the tab bar hidden: a game to pass the time,
/// then Library's shortcuts. Downloads opens what's saved on the phone; the other two need a connection.
struct OfflinePage: View {
    @ObservedObject private var store = DownloadStore.shared

    /// How faded a shortcut that can't open offline is.
    private static let unavailableOpacity = 0.45

    var body: some View {
        // Doesn't scroll: the game takes all the height the shortcuts leave.
        VStack(spacing: 0) {
            SignalCatchCard()
                .padding(.top, Layout.contentTopGap)
                .frame(maxHeight: .infinity)
            HStack(spacing: 10) {
                unavailable(ShortcutTile(title: "Liked Videos", subtitle: "Online only", icon: "hand.thumbsup.fill", tint: .lime, covers: []))
                unavailable(ShortcutTile(title: "Watch Later", subtitle: "Online only", icon: "clock.fill", tint: .yellow, covers: []))
                ZoomLink(wholeLabel: true) {
                    DownloadsView().toolbarVisibility(.hidden, for: .tabBar)
                } label: {
                    ShortcutTile(
                        title: "Downloads",
                        subtitle: store.importing > 0 ? "Adding files…" : store.items.isEmpty ? "Nothing saved" : "\(store.items.count) \(store.items.count == 1 ? "video" : "videos")",
                        icon: "arrow.down.circle.fill",
                        tint: .violet,
                        covers: store.items.prefix(2).map { YouTubeVideo.cover(of: $0.video.videoId) }
                    )
                }
                .buttonStyle(ZoomPressStyle())
                // As on Library's Downloads tile: files from the phone play offline too.
                .contextMenu {
                    Button("Add Files…", systemImage: "folder.badge.plus") { store.picksFiles = true }
                }
            }
            .padding(.horizontal, Layout.screenPadding)
            .padding(.bottom, Layout.sectionGap)
        }
        .toolbarVisibility(.hidden, for: .tabBar)
    }

    private func unavailable(_ tile: ShortcutTile) -> some View {
        tile
            .grayscale(1)
            .opacity(Self.unavailableOpacity)
            .accessibilityHint("Needs a connection")
    }
}

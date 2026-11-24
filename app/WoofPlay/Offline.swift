import Network
import SwiftUI

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

/// Takes the tab's title while offline: a pup asleep next to the word Offline.
struct OfflineTitle: View {
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            SleepingPup()
            Text("Offline")
                .font(.largeTitle)
                .fontWeight(.bold)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Offline")
        .accessibilityAddTraits(.isHeader)
    }
}

/// The Woof apps' offline mark: a curled-up pup whose ear takes the app's accent, with z's floating up.
struct SleepingPup: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var breathes = false

    private static let size = CGSize(width: 64, height: 40)
    /// One z every this many seconds, three in the air at a time.
    private static let zCycle = 3.2

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

/// Home while offline: what's saved on the phone, which plays without a connection.
struct OfflineDownloads: View {
    @ObservedObject private var store = DownloadStore.shared

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if store.items.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing Saved Yet", systemImage: "arrow.down.circle")
                    } description: {
                        Text("Videos you download play here without a connection. Home comes back when you're online.")
                    }
                    .padding(.vertical, 48)
                } else {
                    SectionTitle(title: "Downloads", count: store.items.count)
                    Text("Home comes back by itself when you're online again.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Layout.screenPadding)
                        .padding(.bottom, Layout.chipSpacing)
                    ForEach(store.items) { item in
                        VideoButton(video: item.video, isCompact: true)
                            .padding(.horizontal, Layout.screenPadding)
                            .padding(.vertical, Layout.rowPadding)
                    }
                }
            }
        }
    }
}

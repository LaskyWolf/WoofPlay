import SwiftUI
import SwiftyTube

/// Videos pinned to the front of Quick Picks, newest pin first. Kept on the phone only.
@MainActor @Observable
final class QuickPins {
    static let shared = QuickPins()

    private(set) var videos: [YouTubeVideo] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(videos), forKey: Self.storageKey) }
    }

    private static let storageKey = "quickPicks.pinned"

    private init() {
        videos = UserDefaults.standard.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([YouTubeVideo].self, from: $0) } ?? []
    }

    func isPinned(_ videoId: String) -> Bool { videos.contains { $0.videoId == videoId } }

    func toggle(_ video: YouTubeVideo) {
        if isPinned(video.videoId) {
            videos.removeAll { $0.videoId == video.videoId }
        } else {
            videos.insert(video, at: 0)
        }
    }
}

/// Woof Music's Quick Picks for videos: pages of 2 × 3 covers, pinned videos first, then the top of Home.
struct QuickPicksSection: View {
    let picks: [(video: YouTubeVideo, isPinned: Bool)]
    @Environment(Router.self) private var router
    @State private var page: Int? = 0

    static let columns = 2
    static let perPage = 6
    static let count = 12
    private static let dotSize: CGFloat = 6

    /// Pinned videos, then Home's own videos (no Shorts), up to `count`.
    static func picks(from items: [FeedItem], pinned: [YouTubeVideo]) -> [(video: YouTubeVideo, isPinned: Bool)] {
        let pinnedIds = Set(pinned.map(\.videoId))
        let home = items.compactMap { item -> YouTubeVideo? in
            guard case .video(let video, _) = item, !video.isShort, !pinnedIds.contains(video.videoId) else { return nil }
            return video
        }
        return Array((pinned.map { (video: $0, isPinned: true) } + home.map { (video: $0, isPinned: false) }).prefix(count))
    }

    private var pages: [[(video: YouTubeVideo, isPinned: Bool)]] {
        stride(from: 0, to: picks.count, by: Self.perPage).map { Array(picks[$0..<min($0 + Self.perPage, picks.count)]) }
    }

    var body: some View {
        if !picks.isEmpty {
            VStack(alignment: .leading, spacing: Layout.chipSpacing) {
                SectionTitle(title: "Quick Picks")
                ScrollView(.horizontal, showsIndicators: false) {
                    // Spacing equals the side margin, so the next page stays off screen.
                    LazyHStack(alignment: .top, spacing: Layout.screenPadding) {
                        ForEach(pages.indices, id: \.self) { index in
                            grid(pages[index])
                                .containerRelativeFrame(.horizontal)
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, Layout.screenPadding, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $page)

                if pages.count > 1 {
                    HStack(spacing: Self.dotSize) {
                        ForEach(pages.indices, id: \.self) { index in
                            Circle()
                                .fill(index == (page ?? 0) ? Color.primary : Color.secondary.opacity(0.35))
                                .frame(width: Self.dotSize, height: Self.dotSize)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .animation(.smooth(duration: 0.2), value: page)
                    .accessibilityHidden(true)
                }
            }
            .padding(.vertical, Layout.rowSpacing)
        }
    }

    /// A plain grid, not a lazy one: a lazy grid inside the pager keeps its old rows after a rotation.
    private func grid(_ cards: [(video: YouTubeVideo, isPinned: Bool)]) -> some View {
        let rows = stride(from: 0, to: cards.count, by: Self.columns).map { Array(cards[$0..<min($0 + Self.columns, cards.count)]) }
        return VStack(spacing: Layout.chipSpacing) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: Layout.chipSpacing) {
                    ForEach(rows[row], id: \.video.videoId) { card in
                        QuickPickCard(video: card.video, isPinned: card.isPinned)
                            .frame(maxWidth: .infinity)
                    }
                    // The last row's cards keep the width of a full row's.
                    ForEach(0..<(Self.columns - rows[row].count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

private struct QuickPickCard: View {
    let video: YouTubeVideo
    let isPinned: Bool
    @Environment(Router.self) private var router
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Button { router.openVideo(video) } label: {
            Thumbnail(url: video.thumbnailURL, videoId: video.videoId)
                .overlay(alignment: .bottom) {
                    VideoTitle(video: video)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Layout.chipSpacing)
                        .padding(.bottom, Layout.rowPadding)
                        .padding(.top, Layout.rowSpacing * 2)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                }
                .overlay(alignment: .topLeading) {
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(settings.accentColor)
                            .padding(Layout.rowPadding)
                            .background(.black.opacity(0.55), in: .circle)
                            .padding(Layout.rowPadding)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .clipShape(.rect(cornerRadius: Layout.tileRadius))
                .videoZoomSource(video.videoId)
        }
        .buttonStyle(ZoomPressStyle())
        .accessibilityLabel(isPinned ? "\(video.title), pinned" : video.title)
        // Long press: the usual video menu, which also pins and unpins.
        .videoMenu(video, background: nil)
    }
}

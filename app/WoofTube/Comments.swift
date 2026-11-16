import SwiftUI
import SwiftyTube

/// A comment as SwiftyTube reads it, plus what it leaves out: the reply button, the creator's heart, both like counts.
struct Comment: Identifiable {
    let id: String
    let author: String
    let avatar: String?
    let isCreator: Bool
    let isVerified: Bool
    let runs: [CommentTextRun]
    let time: String?
    let pinnedText: String?
    let likeCount: String
    let likeCountLiked: String
    /// YouTube's own words, such as "722 replies". Past a thousand its count is "1.2K", not a number.
    let repliesLabel: String
    var vote: CommentVoteState
    let likeAction: String?
    let unlikeAction: String?
    let dislikeAction: String?
    let undislikeAction: String?
    let deleteAction: String?
    let editParams: String?
    let reportParams: String?
    let replyParams: String?
    var repliesToken: String?
    var replies: [Comment] = []
    var isLoadingReplies = false
    let isHearted: Bool
    let creatorAvatar: String?
    let heartLabel: String?

    /// Your edit shows at once; YouTube's copy arrives on the next load.
    var editedText: String?

    var plainText: String { editedText ?? CommentsParser.plainText(for: runs) }

    init(_ item: CommentItem, extras: CommentExtras?) {
        id = item.id
        author = item.author.name
        avatar = item.author.avatarURL
        isCreator = item.author.isCreator
        isVerified = item.author.isVerified
        runs = item.runs
        time = item.publishedTime.isEmpty ? nil : item.publishedTime
        pinnedText = item.pinnedText
        likeCount = extras?.likeCount ?? item.likeCountText
        likeCountLiked = extras?.likeCountLiked ?? item.likeCountText
        repliesLabel = extras?.repliesLabel ?? (item.replyCountText.isEmpty ? "Replies" : item.replyCountText)
        vote = item.voteState
        likeAction = item.likeAction
        unlikeAction = item.unlikeAction
        dislikeAction = item.dislikeAction
        undislikeAction = item.undislikeAction
        deleteAction = item.deleteAction
        editParams = item.editParams
        reportParams = item.reportParams
        replyParams = extras?.replyParams
        repliesToken = item.replyContinuation
        isHearted = item.isHearted
        creatorAvatar = extras?.creatorAvatar
        heartLabel = extras?.heartLabel
    }

    /// One you just sent, before YouTube lists it.
    init(own text: String) {
        id = UUID().uuidString
        author = "You"
        avatar = nil
        isCreator = false
        isVerified = false
        runs = [.text(text)]
        time = "Just now"
        pinnedText = nil
        likeCount = ""
        likeCountLiked = ""
        repliesLabel = ""
        vote = .indifferent
        likeAction = nil
        unlikeAction = nil
        dislikeAction = nil
        undislikeAction = nil
        deleteAction = nil
        editParams = nil
        reportParams = nil
        replyParams = nil
        isHearted = false
        creatorAvatar = nil
        heartLabel = nil
    }
}

/// What SwiftyTube's `CommentItem` doesn't carry. A comment's view model links it to its toolbar, which holds the reply button.
struct CommentExtras {
    var replyParams: String?
    var creatorAvatar: String?
    var heartLabel: String?
    var likeCount: String?
    var likeCountLiked: String?
    var repliesLabel: String?

    static func all(in json: [String: Any]) -> [String: CommentExtras] {
        var replyParams: [String: String] = [:]
        var found: [String: CommentExtras] = [:]
        for mutation in JSON.first("mutations", in: json["frameworkUpdates"]) as? [[String: Any]] ?? [] {
            let payload = mutation["payload"] as? [String: Any] ?? [:]
            if let surface = payload["engagementToolbarSurfaceEntityPayload"] as? [String: Any],
               let key = surface["key"] as? String ?? mutation["entityKey"] as? String {
                replyParams[key] = JSON.string("createReplyParams", in: surface)
            }
            if let entity = payload["commentEntityPayload"] as? [String: Any],
               let id = JSON.string("commentId", in: entity["properties"]) {
                let toolbar = entity["toolbar"] as? [String: Any]
                found[id, default: CommentExtras()].creatorAvatar = toolbar?["creatorThumbnailUrl"] as? String
                found[id, default: CommentExtras()].heartLabel = toolbar?["heartActiveTooltip"] as? String
                found[id, default: CommentExtras()].likeCount = toolbar?["likeCountNotliked"] as? String
                found[id, default: CommentExtras()].likeCountLiked = toolbar?["likeCountLiked"] as? String
                found[id, default: CommentExtras()].repliesLabel = toolbar?["replyCountA11y"] as? String
            }
        }
        func link(_ node: Any?) {
            if let dict = node as? [String: Any] {
                if let id = dict["commentId"] as? String, let key = dict["toolbarSurfaceKey"] as? String {
                    found[id, default: CommentExtras()].replyParams = replyParams[key]
                }
                dict.values.forEach(link)
            } else if let array = node as? [Any] {
                array.forEach(link)
            }
        }
        link(json["onResponseReceivedEndpoints"])
        return found
    }
}

/// Comments are read with SwiftyTube's parser and changed through `YouTubeAPI.post`,
/// which answers as the channel you picked when the account has several.
@MainActor
final class CommentsModel: ObservableObject {
    @Published private(set) var comments: [Comment] = []
    @Published private(set) var title: String?
    @Published private(set) var isLoading = true
    @Published private(set) var sortOrder = CommentSort.top
    @Published private(set) var sortTokens: [CommentSort: String] = [:]
    @Published var reportRequest: ReportRequest?
    @Published var notice: String?
    @Published var errorText: String? {
        didSet {
            if let errorText { FileLog.shared.append("comments", "ERROR", errorText) }
        }
    }
    @Published private(set) var didFailLoading = false
    private(set) var createParams: String?
    private var nextToken: String?

    struct ReportRequest: Identifiable {
        let comment: Comment
        let panel: CommentsParser.CommentReportPanel
        var id: String { comment.id }
    }

    private struct Page {
        var comments: [Comment]
        var nextToken: String?
        var page: CommentsPage?
    }

    private func page(_ token: String, replies: Bool = false) async throws -> Page {
        let json = try await InnerTubeClient.wooftube.next(continuation: token)
        return await offMain {
            let extras = CommentExtras.all(in: json)
            if replies {
                let page = CommentsParser.parseRepliesPage(json)
                return Page(comments: page.items.map { Comment($0, extras: extras[$0.id]) }, nextToken: page.nextPageToken)
            }
            let page = CommentsParser.parseCommentsPage(json)
            return Page(comments: page.items.map { Comment($0, extras: extras[$0.id]) }, nextToken: page.nextPageToken, page: page)
        }
    }

    func load(token: String) async {
        defer { isLoading = false }
        didFailLoading = false
        isLoading = true
        do {
            let result = try await page(token)
            comments = result.comments
            nextToken = result.nextToken
            title = result.page?.totalCountText ?? title
            // Only the first page carries these, so a re-sorted page keeps the old ones.
            if let params = result.page?.createCommentParams { createParams = params }
            if let tokens = result.page?.sortTokens, !tokens.isEmpty { sortTokens = tokens }
        } catch {
            didFailLoading = true
        }
    }

    func sort(by order: CommentSort) async {
        guard order != sortOrder, let token = sortTokens[order] else { return }
        sortOrder = order
        comments = []
        await load(token: token)
    }

    func loadMore(after comment: Comment) async {
        guard comment.id == comments.last?.id, let token = nextToken else { return }
        nextToken = nil
        guard let result = try? await page(token) else {
            nextToken = token
            return
        }
        comments += result.comments
        nextToken = result.nextToken
    }

    /// Each call adds the next page. A failure is shown, because a silent one looks like a dead button.
    func loadReplies(of comment: Comment) async {
        guard let token = comment.repliesToken, !comment.isLoadingReplies else { return }
        update(comment.id) { $0.isLoadingReplies = true }
        defer { update(comment.id) { $0.isLoadingReplies = false } }
        do {
            let result = try await page(token, replies: true)
            if result.comments.isEmpty { errorText = "YouTube returned no replies for this comment." }
            update(comment.id) {
                $0.replies += result.comments
                $0.repliesToken = result.nextToken
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Tapping the side you already picked takes the vote back.
    func vote(_ comment: Comment, _ side: CommentVoteState) async {
        let target = comment.vote == side ? CommentVoteState.indifferent : side
        let action: String? = switch target {
        case .liked: comment.likeAction
        case .disliked: comment.dislikeAction
        case .indifferent: comment.vote == .liked ? comment.unlikeAction : comment.undislikeAction
        }
        guard let action else {
            errorText = "Sign in to rate comments."
            return
        }
        let before = comment.vote
        update(comment.id) { $0.vote = target }
        do {
            try await perform(action)
        } catch {
            update(comment.id) { $0.vote = before }
            errorText = error.localizedDescription
        }
    }

    /// Returns whether it was sent, so the composer keeps the text after a failure.
    func send(_ text: String, replyingTo parent: Comment?) async -> Bool {
        do {
            if let parent {
                guard let params = parent.replyParams else {
                    throw YouTubeAPIError(errorDescription: "YouTube didn't offer a reply button for this comment.")
                }
                try Self.check(await YouTubeAPI.post("comment/create_comment_reply", body: ["commentText": text, "createReplyParams": params]))
                update(parent.id) { $0.replies.append(Comment(own: text)) }
            } else {
                guard let params = createParams else {
                    throw YouTubeAPIError(errorDescription: "Comments can't be added to this video.")
                }
                try Self.check(await YouTubeAPI.post("comment/create_comment", body: ["commentText": text, "createCommentParams": params]))
                comments.insert(Comment(own: text), at: 0)
            }
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    func edit(_ comment: Comment, to text: String) async -> Bool {
        guard let params = comment.editParams else { return false }
        do {
            let json = try await YouTubeAPI.post("comment/update_comment", body: ["commentText": text, "updateCommentParams": params])
            try Self.checkResults(json)
            update(comment.id) { $0.editedText = text }
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    func delete(_ comment: Comment) async {
        guard let action = comment.deleteAction else { return }
        do {
            try await perform(action)
            comments.removeAll { $0.id == comment.id }
            for index in comments.indices { comments[index].replies.removeAll { $0.id == comment.id } }
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Opens YouTube's list of reasons. The choice is sent by `report(_:reason:)`.
    func startReport(_ comment: Comment) async {
        guard let params = comment.reportParams else { return }
        do {
            let json = try await YouTubeAPI.post("get_panel", body: ["panelId": "PAabuse_report", "params": params])
            guard let panel = CommentsParser.parseReportPanel(json) else {
                throw YouTubeAPIError(errorDescription: "YouTube didn't offer a way to report this comment.")
            }
            reportRequest = ReportRequest(comment: comment, panel: panel)
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// YouTube's report form goes reason → optional details → confirmation. The details step is sent empty.
    func report(_ request: ReportRequest, reason: CommentsParser.CommentReportReason) async {
        var state = request.panel.flowState
        var key = request.panel.flowStateEntityKey
        var route = (flowId: request.panel.flowId, targetId: request.panel.targetId)
        guard var abuse = state["abuseReportFlowState"] as? [String: Any] else {
            errorText = "YouTube's report form changed, so WoofTube can't send it."
            return
        }
        abuse["reasonKey"] = reason.key
        abuse["navigationEnabled"] = true
        abuse["isReportFormDirty"] = true
        abuse["navigationCommand"] = reason.command
        state["abuseReportFlowState"] = abuse
        do {
            // Reason, then details: two steps reach the confirmation; the third is slack.
            for _ in 0..<3 {
                let json = try await YouTubeAPI.post("flow", body: [
                    "flowId": route.flowId, "targetId": route.targetId, "flowState": state, "flowStateEntityKey": key
                ])
                let update = CommentsParser.parseReportFlowUpdate(json)
                guard case .steps(let steps) = update.outcome else {
                    if case .failure(let text) = update.outcome { throw YouTubeAPIError(errorDescription: text ?? "YouTube didn't accept the report.") }
                    throw YouTubeAPIError(errorDescription: "YouTube didn't accept the report.")
                }
                if let next = update.flowState { state = next }
                if let next = update.flowStateEntityKey { key = next }
                if let command = (state["abuseReportFlowState"] as? [String: Any])?["navigationCommand"] as? [String: Any], !command.isEmpty {
                    let next = CommentsParser.flowRoute(from: command)
                    route = (next.flowId, next.targetId)
                }
                let parsed = steps.map(CommentsParser.parseReportStep)
                let step = parsed.first { $0.stepId != nil && $0.stepId == state["currentStepId"] as? String } ?? parsed.last
                switch step?.page {
                case .confirmation:
                    notice = "Thanks. YouTube will review this comment."
                    return
                case .details:
                    state["flowFormState"] = ["isValid": true]
                case .signIn:
                    throw YouTubeAPIError(errorDescription: "Sign in to report comments.")
                default:
                    throw YouTubeAPIError(errorDescription: "YouTube's report form changed, so WoofTube can't send it.")
                }
            }
            throw YouTubeAPIError(errorDescription: "YouTube didn't finish the report.")
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func perform(_ action: String) async throws {
        try Self.checkResults(await YouTubeAPI.post("comment/perform_comment_action", body: ["actions": [action]]))
    }

    /// Votes, edits and deletes answer with `actionResults`.
    private static func checkResults(_ json: [String: Any]) throws {
        let status = (json["actionResults"] as? [[String: Any]])?.first?["status"] as? String
        guard status == nil || status == "STATUS_SUCCEEDED" else {
            throw YouTubeAPIError(errorDescription: "YouTube refused this action.")
        }
    }

    /// A new comment or reply is refused with an error toast instead.
    private static func check(_ json: [String: Any]) throws {
        if let error = JSON.first("showErrorAction", in: json) {
            throw YouTubeAPIError(errorDescription: JSON.text(JSON.first("text", in: error)) ?? "YouTube refused this comment.")
        }
    }

    private func update(_ id: String, _ change: (inout Comment) -> Void) {
        for index in comments.indices {
            if comments[index].id == id {
                change(&comments[index])
                return
            }
            if let reply = comments[index].replies.firstIndex(where: { $0.id == id }) {
                change(&comments[index].replies[reply])
                return
            }
        }
    }
}

struct CommentsSheet: View {
    let token: String

    @StateObject private var model = CommentsModel()
    @State private var draft = ""
    @State private var replyingTo: Comment?
    @State private var editing: Comment?
    @State private var deleting: Comment?
    @State private var detent = PresentationDetent.medium
    @State private var seeks = 0
    @Environment(Router.self) private var router
    @State private var isSending = false
    @FocusState private var isComposing: Bool

    private static let replyInsets = EdgeInsets(top: Layout.rowPadding, leading: Layout.screenPadding + 44, bottom: Layout.rowPadding, trailing: Layout.screenPadding)

    var body: some View {
        NavigationStack {
            list
                .navigationTitle(model.title ?? "Comments")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { sortMenu }
                // A time in a comment plays the video from there, with the sheet lowered to half so it shows.
                .environment(\.openURL, OpenURLAction { router.openDescriptionLink($0) {
                    seeks += 1
                    withAnimation { detent = .medium }
                } })
                .sensoryFeedback(.impact(weight: .medium), trigger: seeks)
                .safeAreaInset(edge: .bottom) { composer }
                .modifier(alerts)
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .task { await model.load(token: token) }
    }

    // Split out of `body`, which grew past what the compiler type-checks in time.
    private var list: some View {
        List {
            ForEach(model.comments) { comment in
                CommentRow(comment: comment, model: model, onReply: reply(to:), onEdit: edit, onDelete: { deleting = $0 })
                    .listRowInsets(Layout.rowInsets)
                    .task { await model.loadMore(after: comment) }
                ForEach(comment.replies) { child in
                    CommentRow(comment: child, model: model, onReply: reply(to:), onEdit: edit, onDelete: { deleting = $0 })
                        .listRowInsets(Self.replyInsets)
                }
                if !comment.replies.isEmpty, comment.repliesToken != nil {
                    Button {
                        Task { await model.loadReplies(of: comment) }
                    } label: {
                        Group {
                            if comment.isLoadingReplies {
                                ProgressView()
                            } else {
                                Text("Show More Replies")
                            }
                        }
                        .font(.footnote.weight(.medium))
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                    }
                    .foregroundStyle(.tint)
                    .buttonStyle(ZoomPressStyle())
                    .listRowInsets(Self.replyInsets)
                    .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if model.comments.isEmpty {
                if model.isLoading {
                    LoadingTextRows()
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, Layout.rowSpacing)
                } else if model.didFailLoading {
                    ContentUnavailableView {
                        Label("Couldn't Load", systemImage: "exclamationmark.triangle")
                    } actions: {
                        Button("Try Again") { Task { await model.load(token: token) } }
                            .buttonStyle(.bordered)
                    }
                } else {
                    ContentUnavailableView("No Comments", systemImage: "bubble.left")
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var sortMenu: some ToolbarContent {
        if model.sortTokens.count > 1 {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Sort", systemImage: "arrow.up.arrow.down") {
                    Picker("Sort", selection: Binding(get: { model.sortOrder }, set: { order in Task { await model.sort(by: order) } })) {
                        ForEach(CommentSort.allCases) { Text($0.title).tag($0) }
                    }
                }
            }
        }
    }

    private var alerts: CommentAlerts {
        CommentAlerts(model: model, deleting: $deleting)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Layout.chipSpacing) {
            if let banner = editing.map({ _ in "Editing your comment" }) ?? replyingTo.map({ "Replying to \($0.author)" }) {
                HStack(spacing: Layout.chipSpacing) {
                    Text(banner)
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Cancel", systemImage: "xmark.circle.fill") {
                        if editing != nil { draft = "" }
                        editing = nil
                        replyingTo = nil
                    }
                        .labelStyle(.iconOnly)
                        .buttonStyle(ZoomPressStyle())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .padding(.leading, Layout.screenPadding)
                .background(.regularMaterial, in: .capsule)
            }
            HStack(alignment: .bottom, spacing: Layout.chipSpacing) {
                TextField("Add a comment", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($isComposing)
                    .padding(.horizontal, Layout.screenPadding)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
                Button("Send", systemImage: "arrow.up") {
                    Task { await send() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            }
        }
        .padding(.horizontal, Layout.screenPadding)
        .padding(.vertical, Layout.chipSpacing)
    }

    private func reply(to comment: Comment) {
        editing = nil
        replyingTo = comment
        isComposing = true
    }

    private func edit(_ comment: Comment) {
        replyingTo = nil
        editing = comment
        draft = comment.plainText
        isComposing = true
    }

    private func send() async {
        isSending = true
        defer { isSending = false }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let sent: Bool
        if let editing {
            sent = await model.edit(editing, to: text)
        } else {
            sent = await model.send(text, replyingTo: replyingTo)
        }
        if sent {
            draft = ""
            editing = nil
            replyingTo = nil
            isComposing = false
        }
    }
}

/// The report, delete and error dialogs of the comments sheet.
private struct CommentAlerts: ViewModifier {
    @ObservedObject var model: CommentsModel
    @Binding var deleting: Comment?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                model.reportRequest?.panel.pageHeader ?? "Report Comment",
                isPresented: Binding(get: { model.reportRequest != nil }, set: { if !$0 { model.reportRequest = nil } }),
                titleVisibility: .visible,
                presenting: model.reportRequest
            ) { request in
                ForEach(request.panel.reasons, id: \.key) { reason in
                    Button(reason.text ?? reason.key) { Task { await model.report(request, reason: reason) } }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                "Delete this comment?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible,
                presenting: deleting
            ) { comment in
                Button("Delete", role: .destructive) { Task { await model.delete(comment) } }
            }
            .alert(model.notice ?? "", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .alert("That Didn't Work", isPresented: Binding(get: { model.errorText != nil }, set: { if !$0 { model.errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorText ?? "")
            }
    }
}

private struct CommentRow: View {
    let comment: Comment
    @ObservedObject var model: CommentsModel
    let onReply: (Comment) -> Void
    let onEdit: (Comment) -> Void
    let onDelete: (Comment) -> Void
    @Environment(Router.self) private var router

    private static let heartAvatarSize: CGFloat = 24

    var body: some View {
        HStack(alignment: .top, spacing: Layout.rowSpacing) {
            Avatar(url: comment.avatar, size: Layout.avatarSmall)
            VStack(alignment: .leading, spacing: Layout.rowPadding) {
                if let pinned = comment.pinnedText {
                    Label(pinned, systemImage: "pin.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    // The creator's name sits on a pill, as on YouTube.
                    Text(comment.author)
                        .foregroundStyle(comment.isCreator ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, comment.isCreator ? Layout.cardSpacing + 2 : 0)
                        .background(comment.isCreator ? Color.secondary : .clear, in: .capsule)
                    if comment.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .accessibilityLabel("Verified")
                    }
                    if let time = comment.time {
                        Text("· \(time)")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                Text(text)
                    .font(.subheadline)
                    .tint(.accentColor)
                    .textSelection(.enabled)
                HStack(spacing: 16) {
                    voteButton(.liked)
                    voteButton(.disliked)
                    if comment.replyParams != nil {
                        Button {
                            onReply(comment)
                        } label: {
                            Text("Reply").frame(minHeight: 44).contentShape(.rect)
                        }
                    }
                    if comment.repliesToken != nil, comment.replies.isEmpty {
                        Button {
                            Task { await model.loadReplies(of: comment) }
                        } label: {
                            Group {
                                if comment.isLoadingReplies {
                                    ProgressView()
                                } else {
                                    Text(comment.repliesLabel)
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                        }
                    }
                    if comment.isHearted {
                        ZStack(alignment: .bottomTrailing) {
                            Avatar(url: comment.creatorAvatar, size: Self.heartAvatarSize)
                            Image(systemName: "heart.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                                .offset(x: 3, y: 3)
                        }
                        .accessibilityElement()
                        .accessibilityLabel(comment.heartLabel ?? "Hearted by the creator")
                    }
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(.tint)
                .buttonStyle(ZoomPressStyle())
                .foregroundStyle(.secondary)
                .sensoryFeedback(.impact(weight: .light), trigger: comment.vote)
            }
        }
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = comment.plainText
            }
            if comment.editParams != nil {
                Button("Edit", systemImage: "pencil") { onEdit(comment) }
            }
            if comment.deleteAction != nil {
                Button("Delete", systemImage: "trash", role: .destructive) { onDelete(comment) }
            }
            if comment.reportParams != nil {
                Button("Report", systemImage: "flag") { Task { await model.startReport(comment) } }
            }
        }
        .listRowSeparator(.hidden)
    }

    /// Links open in the app, and a time like 1:23 jumps there in the video.
    private var text: AttributedString {
        if let edited = comment.editedText { return AttributedString(edited) }
        var out = AttributedString()
        for run in comment.runs {
            switch run {
            case .text(let text):
                out += AttributedString(text)
            case .link(let text, let url):
                var part = AttributedString(text)
                part.link = url
                out += part
            case .timestamp(let text, let seconds, let videoId):
                var part = AttributedString(text)
                if let id = videoId ?? router.current?.videoId {
                    part.link = URL(string: "https://www.youtube.com/watch?v=\(id)&t=\(Int(seconds))s")
                }
                out += part
            }
        }
        return out
    }

    /// The count sits by the thumb up only, as YouTube shows no dislike count.
    private func voteButton(_ side: CommentVoteState) -> some View {
        let isOn = comment.vote == side
        let isLike = side == .liked
        let symbol = isLike ? "hand.thumbsup" : "hand.thumbsdown"
        return Button {
            Task { await model.vote(comment, side) }
        } label: {
            Label {
                if isLike { Text(isOn ? comment.likeCountLiked : comment.likeCount) }
            } icon: {
                Image(systemName: isOn ? symbol + ".fill" : symbol)
                    .glyphMotion(isOn ? .pop : .deflate, trigger: isOn)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
        }
        .accessibilityLabel(isLike ? "Like" : "Dislike")
        .accessibilityValue(isLike ? (isOn ? comment.likeCountLiked : comment.likeCount) : "")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

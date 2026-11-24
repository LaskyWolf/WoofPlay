import Foundation
import TorrentNative

/// Downloads shared magnet links with libtorrent. Finished video and audio files move into Downloads.
@MainActor
final class TorrentStore: ObservableObject {
    static let shared = TorrentStore()

    /// What the app keeps between launches. Partial files are checked again by libtorrent on the next start.
    struct Job: Codable, Identifiable {
        let id: String
        let magnet: String
        let folder: String
    }

    /// The engine's report for one torrent.
    struct Status: Decodable {
        let id: String
        let state: String
        let name: String
        var error: String?
        let progress: Double
        let rate: Int
        let peers: Int
        let files: [String]
    }

    @Published private(set) var jobs: [Job] = []
    @Published private(set) var statuses: [String: Status] = [:]
    /// Shows a problem found while downloading. The router sets it.
    var onProblem: ((String) -> Void)?

    private let session: OpaquePointer?
    private var poll: Task<Void, Never>?

    private static let root = URL.applicationSupportDirectory.appending(path: "Torrents", directoryHint: .isDirectory)
    private static let index = root.appending(path: "jobs.json")

    private init() {
        session = wp_session_create()
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        var root = Self.root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        let saved = (try? Data(contentsOf: Self.index)).flatMap { try? JSONDecoder().decode([Job].self, from: $0) } ?? []
        for job in saved where (try? start(job.magnet, in: job.folder)) != nil { jobs.append(job) }
        watch()
    }

    /// Starts a magnet link. Returns the error to show, or nil.
    func add(_ magnet: URL) -> String? {
        guard session != nil else { return "The torrent engine didn't start." }
        let folder = UUID().uuidString
        do {
            let id = try start(magnet.absoluteString, in: folder)
            guard !jobs.contains(where: { $0.id == id }) else { return nil }
            jobs.append(Job(id: id, magnet: magnet.absoluteString, folder: folder))
            save()
            watch()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func cancel(_ job: Job) {
        wp_remove(session, job.id, 1)
        finish(job)
    }

    private func start(_ magnet: String, in folder: String) throws -> String {
        let path = Self.root.appending(path: folder).path
        var out = [CChar](repeating: 0, count: 512)
        let result = wp_add_magnet(session, magnet, path, &out, Int32(out.count))
        let text = String(cString: out)
        guard result == 0 else { throw TorrentError(message: text) }
        return text
    }

    /// Asks the engine once a second while anything is downloading.
    private func watch() {
        guard poll == nil, !jobs.isEmpty else { return }
        poll = Task { [weak self] in
            while let self, !self.jobs.isEmpty, !Task.isCancelled {
                self.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
            self?.poll = nil
        }
    }

    private func refresh() {
        let needed = Int(wp_status(session, nil, 0)) + 1
        var out = [CChar](repeating: 0, count: needed)
        wp_status(session, &out, Int32(needed))
        let list = (try? JSONDecoder().decode([Status].self, from: Data(String(cString: out).utf8))) ?? []
        statuses = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for job in jobs {
            guard let status = statuses[job.id] else { continue }
            switch status.state {
            case "finished":
                DownloadStore.shared.addFiles(status.files.map { URL(filePath: $0) }, moving: true)
                wp_remove(session, job.id, 0)
                finish(job)
            case "noMedia":
                wp_remove(session, job.id, 1)
                finish(job)
                onProblem?("This torrent has no video or audio files, so nothing was downloaded.")
            default:
                break
            }
        }
    }

    /// Forgets the job and deletes what's left of its folder.
    private func finish(_ job: Job) {
        try? FileManager.default.removeItem(at: Self.root.appending(path: job.folder))
        jobs.removeAll { $0.id == job.id }
        statuses[job.id] = nil
        save()
    }

    private func save() {
        try? JSONEncoder().encode(jobs).write(to: Self.index, options: .atomic)
    }

    private struct TorrentError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

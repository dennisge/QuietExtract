import AppKit
import Foundation

struct Job: Identifiable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case extract = "Extract", compress = "Compress", verify = "Verify"

        var id: Self { self }
        var activity: String {
            switch self {
            case .extract: "Extracting"
            case .compress: "Compressing"
            case .verify: "Verifying"
            }
        }
    }

    enum Status {
        case waiting, running, password(Bool), done(URL, String?), failed(String), cancelled
    }

    let id = UUID()
    let source: URL
    let title: String
    let kind: Kind
    var status: Status = .waiting
}

struct JobDialog: Identifiable {
    enum Content {
        case compression([URL])
        case password(UUID, String, Bool)
    }

    let id = UUID()
    let content: Content
}

@MainActor
final class Jobs: ObservableObject {
    private struct Pending {
        var password: String?
        var compression: ([URL], CompressionOptions)?
    }

    private struct Output: Sendable {
        let url: URL
        var trash: [URL] = []
        var note: String?
    }

    @Published private(set) var items: [Job] = []
    @Published var mode: Job.Kind = .extract
    @Published var dialog: JobDialog?
    private var pending: [UUID: Pending] = [:]
    private var active: Task<Output, Error>?
    private var terminationReply: (() -> Void)?

    func enqueue(_ urls: [URL], kind: Job.Kind) {
        guard terminationReply == nil else { return }
        let files = urls.filter(\.isFileURL)
        if kind == .compress {
            guard !files.isEmpty, dialog == nil else { return }
            dialog = JobDialog(content: .compression(files))
            return
        }
        var seen: Set<URL> = []
        for file in files {
            let source = (try? ArchiveEngine.input(file)) ?? file
            guard seen.insert(source).inserted else { continue }
            let job = Job(source: source, title: source.lastPathComponent, kind: kind)
            pending[job.id] = Pending()
            items.append(job)
        }
        startNext()
    }

    func compress(_ files: [URL], options: CompressionOptions) {
        guard let source = files.first, terminationReply == nil else { return }
        let job = Job(source: source, title: options.name + "." + options.format.rawValue, kind: .compress)
        pending[job.id] = Pending(compression: (files, options))
        items.append(job)
        startNext()
    }

    func requestPassword(for job: Job, retry: Bool) {
        guard dialog == nil else { return }
        dialog = JobDialog(content: .password(job.id, job.title, retry))
    }

    func unlock(_ id: UUID, password: String) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              case .password = items[index].status else { return }
        dialog = nil
        pending[id] = Pending(password: password)
        items[index].status = .waiting
        startNext()
    }

    func cancel() { active?.cancel() }

    func prepareToQuit(reply: @escaping () -> Void) -> Bool {
        guard active != nil else { return true }
        terminationReply = reply
        cancel()
        return false
    }

    private func startNext() {
        guard active == nil, let index = items.firstIndex(where: {
            if case .waiting = $0.status { return true }
            return false
        }) else { return }

        let id = items[index].id
        let source = items[index].source
        let kind = items[index].kind
        guard let work = pending.removeValue(forKey: id) else { return }
        items[index].status = .running
        let task = Task.detached(priority: .userInitiated) {
            switch kind {
            case .extract: return Output(url: try Extractor.extract(source, password: work.password))
            case .verify: return Output(url: try ArchiveEngine.verify(source, password: work.password))
            case .compress:
                guard let (files, options) = work.compression else {
                    throw ExtractionError(message: "Compression settings are missing.")
                }
                let before = options.trashSources ? try SourceSnapshot.read(files) : nil
                let url = try Compressor.create(from: files, options: options)
                guard let before else { return Output(url: url) }
                if (try? SourceSnapshot.read(files)) == before {
                    return Output(url: url, trash: files)
                }
                return Output(url: url, note: "Originals changed during compression and were kept.")
            }
        }
        active = task
        Task {
            switch await task.result {
            case .success(let result):
                var note = result.note
                if !result.trash.isEmpty && !task.isCancelled {
                    let failed: Bool = await withCheckedContinuation { continuation in
                        NSWorkspace.shared.recycle(result.trash) { _, error in
                            continuation.resume(returning: error != nil)
                        }
                    }
                    note = failed ? "Some originals could not be moved to Trash." : "Originals moved to Trash."
                }
                items[index].status = .done(result.url, note)
            case .failure(let error as PasswordRequired):
                items[index].status = .password(error.retry)
                if terminationReply == nil { requestPassword(for: items[index], retry: error.retry) }
            case .failure(is CancellationError):
                items[index].status = .cancelled
            case .failure(let error):
                items[index].status = .failed(error.localizedDescription)
            }
            active = nil
            if let terminationReply { terminationReply() } else { startNext() }
        }
    }
}

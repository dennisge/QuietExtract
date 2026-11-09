import AppKit
import SwiftUI

struct WindowContent: View {
    @ObservedObject var jobs: Jobs
    @ObservedObject var dropState: DropState
    let chooseFiles: (Job.Kind) -> Void

    var body: some View {
        VStack(spacing: 15) {
            Picker("Archive operation", selection: $jobs.mode) {
                ForEach(Job.Kind.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            dropZone
            if jobs.items.isEmpty {
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(jobs.items.reversed()) { job in
                            jobRow(job)
                            if job.id != jobs.items.first?.id { Divider().padding(.leading, 42) }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .frame(minHeight: 88)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            }
            Label("Processed on this Mac", systemImage: "lock.shield")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(22)
        .frame(minWidth: 440, minHeight: 370)
        .sheet(item: $jobs.dialog) { dialog in
            switch dialog.content {
            case .compression(let files):
                CompressionSheet(files: files) { jobs.compress(files, options: $0) }
            case .password(let id, let title, let retry):
                PasswordSheet(title: title, retry: retry) { jobs.unlock(id, password: $0) }
            }
        }
    }

    private var dropZone: some View {
        let mode = jobs.mode
        let title = dropState.isTargeted ? "Release to " + mode.rawValue.lowercased()
            : (mode == .compress ? "Drop files or folders" : "Drop archives here")
        let subtitle: String = switch mode {
        case .extract: "ZIP, RAR, 7z and tar.gz"
        case .compress: "Create a ZIP or 7z archive"
        case .verify: "Check an archive without extracting it"
        }
        let icon: String = switch mode {
        case .extract: "archivebox"
        case .compress: "doc.zipper"
        case .verify: "checkmark.shield"
        }
        return VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 54, height: 54)
                .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 15))
                .accessibilityHidden(true)
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).foregroundStyle(.secondary)
            Button(mode == .compress ? "Choose Items…" : "Choose Archives…") { chooseFiles(mode) }
                .buttonStyle(.borderedProminent)
                .padding(.top, 5)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(Color.accentColor.opacity(dropState.isTargeted ? 0.15 : 0.05),
                    in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.accentColor.opacity(dropState.isTargeted ? 0.8 : 0.25),
                              style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                .allowsHitTesting(false)
        }
    }

    private func jobRow(_ job: Job) -> some View {
        HStack(spacing: 10) {
            Image(systemName: job.kind == .verify ? "checkmark.shield" : "doc.zipper")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(job.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(job.source.path)
                switch job.status {
                case .waiting: status("Waiting")
                case .running: status(job.kind.activity + "…")
                case .password(let retry): status(retry ? "Password rejected" : "Password required")
                case .done(let output, let note):
                    status(job.kind == .verify ? "Integrity check passed" : "Saved as " + output.lastPathComponent)
                    if let note { status(note) }
                case .cancelled: status("Cancelled")
                case .failed(let error):
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            switch job.status {
            case .running:
                ProgressView().controlSize(.small)
                Button("Cancel", action: jobs.cancel)
            case .password(let retry):
                Button("Unlock…") { jobs.requestPassword(for: job, retry: retry) }
            case .done(let output, _):
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
            default:
                EmptyView()
            }
        }
        .padding(.vertical, 9)
    }

    private func status(_ message: String) -> some View {
        Text(message).font(.caption).foregroundStyle(.secondary)
    }
}

@MainActor
final class DropState: ObservableObject {
    @Published var isTargeted = false
}

final class ArchiveDropView: NSView {
    private let dropState: DropState
    private let receive: ([URL]) -> Void

    init(rootView: WindowContent, dropState: DropState, receive: @escaping ([URL]) -> Void) {
        self.dropState = dropState
        self.receive = receive
        super.init(frame: .zero)
        let hosting = NSHostingView(rootView: rootView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        registerForDraggedTypes([.fileURL])
    }

    @MainActor required dynamic init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let accepted = !fileURLs(from: sender).isEmpty
        dropState.isTargeted = accepted
        return accepted ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropState.isTargeted ? .copy : []
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropState.isTargeted
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropState.isTargeted = false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropState.isTargeted = false
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        receive(urls)
        return true
    }

    private func fileURLs(from sender: any NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}

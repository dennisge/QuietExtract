import CArchive
import Darwin
import Foundation

struct ExtractionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Extractor {
    static func extract(_ selected: URL, password: String? = nil) throws -> URL {
        let source = try ArchiveEngine.input(selected)
        try Task.checkCancellation()
        let input = open(source.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard input >= 0 else { throw systemError("Could not open the archive") }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0 else { throw systemError("Could not inspect the archive") }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw ExtractionError(message: "Choose a regular archive file.")
        }

        let work = try ArchiveEngine.makeWorkspace(in: source.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: work) }
        let stage = work.appendingPathComponent("result", isDirectory: true)
        guard mkdir(stage.path, 0o700) == 0 else { throw systemError("Could not prepare the extraction folder") }

        if password != nil || ArchiveEngine.isVolume(source) {
            try ArchiveEngine.run(["x", "-y", "-aou", "-o\(stage.path)", "--", source.path],
                                  password: password, in: work, restrictedTo: stage)
            try checkEngineOutput(stage)
        } else {
            try unpack(input, to: stage)
        }
        try preserveQuarantine(from: input, in: stage)
        try Task.checkCancellation()
        let stem = ArchiveEngine.archiveName(source)
        let name = stem.isEmpty || stem == "." || stem == ".." ? "Extracted Archive" : stem
        return try ArchiveEngine.publish(stage, in: work.deletingLastPathComponent(), name: name)
    }

    private static func checkEngineOutput(_ stage: URL) throws {
        var scanError: Error?
        guard let files = FileManager.default.enumerator(at: stage, includingPropertiesForKeys: [],
            errorHandler: { _, error in scanError = error; return false }) else {
            throw ExtractionError(message: "Could not inspect the extracted files.")
        }
        for case let file as URL in files {
            try Task.checkCancellation()
            var info = stat()
            guard lstat(file.path, &info) == 0 else { throw systemError("Could not inspect an extracted item") }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFDIR || (kind == S_IFREG && info.st_nlink == 1) else {
                throw ExtractionError(message: "Links and special files are unsupported: \(file.lastPathComponent)")
            }
            let mode: mode_t = kind == S_IFDIR ? 0o700 : (0o600 | (info.st_mode & 0o100))
            guard chmod(file.path, mode) == 0 else { throw systemError("Could not set extracted file permissions") }
        }
        if let scanError { throw scanError }
    }

    private static func unpack(_ input: Int32, to stage: URL) throws {
        guard let reader = archive_read_new() else {
            throw ExtractionError(message: "Could not initialize the archive reader.")
        }
        defer { archive_read_free(reader) }
        guard let writer = archive_write_disk_new() else {
            throw ExtractionError(message: "Could not initialize the archive writer.")
        }
        defer { archive_write_free(writer) }

        try check(archive_read_support_filter_gzip(reader), reader)
        try check(archive_read_support_format_zip(reader), reader)
        try check(archive_read_support_format_rar(reader), reader)
        try check(archive_read_support_format_rar5(reader), reader)
        try check(archive_read_support_format_7zip(reader), reader)
        try check(archive_read_support_format_tar(reader), reader)
        try check(archive_write_disk_set_options(writer,
            ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_NO_OVERWRITE |
            ARCHIVE_EXTRACT_SECURE_SYMLINKS | ARCHIVE_EXTRACT_SECURE_NODOTDOT), writer)
        try check(archive_read_open_fd(reader, input, 64 * 1024), reader)

        while true {
            try Task.checkCancellation()
            var entry: OpaquePointer?
            let status = archive_read_next_header(reader, &entry)
            if status == ARCHIVE_EOF { break }
            try check(status, reader)
            guard let entry else { throw ExtractionError(message: "Invalid archive entry.") }
            try extractEntry(entry, reader: reader, writer: writer, stage: stage)
        }
        try check(archive_read_close(reader), reader)
        try check(archive_write_close(writer), writer)
    }

    private static func extractEntry(_ entry: OpaquePointer, reader: OpaquePointer,
                                     writer: OpaquePointer, stage: URL) throws {
        guard let name = archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry),
              let path = String(validatingCString: name) else {
            throw ExtractionError(message: "The archive contains a filename that could not be decoded.")
        }
        let fileType = UInt32(archive_entry_filetype(entry))
        let isDirectory = fileType == UInt32(S_IFDIR)
        guard (isDirectory || fileType == UInt32(S_IFREG)),
              archive_entry_hardlink(entry) == nil, archive_entry_symlink(entry) == nil else {
            throw ExtractionError(message: "Links and special files are unsupported: \(path)")
        }
        guard archive_entry_is_encrypted(entry) != 1 else {
            throw PasswordRequired(retry: false)
        }

        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/").filter { $0 != "." }
        guard !normalized.hasPrefix("/"), !components.contains(".."),
              components.first?.dropFirst().first != ":" else {
            throw ExtractionError(message: "Unsafe path in archive: \(path)")
        }
        if components.isEmpty {
            guard isDirectory else { throw ExtractionError(message: "Invalid archive path: \(path)") }
            return
        }
        let target = stage.path + "/" + components.joined(separator: "/")
        var existing = stat()
        if lstat(target, &existing) == 0 {
            guard isDirectory, (existing.st_mode & S_IFMT) == S_IFDIR else {
                throw ExtractionError(message: "Duplicate path in archive: \(path)")
            }
        } else if errno != ENOENT {
            throw systemError("Could not prepare an extracted file")
        }

        archive_entry_set_pathname(entry, target)
        let executable = archive_entry_perm(entry) & 0o100
        archive_entry_set_perm(entry, isDirectory ? 0o700 : (0o600 | executable))
        try check(archive_write_header(writer, entry), writer)
        while true {
            try Task.checkCancellation()
            var buffer: UnsafeRawPointer?
            var count = 0
            var offset: Int64 = 0
            let status = archive_read_data_block(reader, &buffer, &count, &offset)
            if status == ARCHIVE_EOF { break }
            try check(status, reader)
            let written = archive_write_data_block(writer, buffer, count, offset)
            if written < 0 { throw archiveError(writer) }
        }
        try check(archive_write_finish_entry(writer), writer)
    }

    private static func preserveQuarantine(from input: Int32, in stage: URL) throws {
        let name = "com.apple.quarantine"
        let length = fgetxattr(input, name, nil, 0, 0, 0)
        if length < 0 && errno == ENOATTR { return }
        guard length > 0 else {
            if length == 0 { return }
            throw systemError("Could not read the archive's quarantine metadata")
        }
        var bytes = [UInt8](repeating: 0, count: length)
        let read = bytes.withUnsafeMutableBytes { fgetxattr(input, name, $0.baseAddress, length, 0, 0) }
        guard read > 0 else { throw systemError("Could not read the archive's quarantine metadata") }
        var enumerationError: Error?
        guard let items = FileManager.default.enumerator(at: stage, includingPropertiesForKeys: [],
            errorHandler: { _, error in enumerationError = error; return false }) else {
            throw ExtractionError(message: "Could not inspect the extracted files.")
        }
        func apply(to item: URL) throws {
            try Task.checkCancellation()
            let result = bytes.withUnsafeBytes {
                setxattr(item.path, name, $0.baseAddress, read, 0, XATTR_NOFOLLOW)
            }
            guard result == 0 else { throw systemError("Could not preserve quarantine metadata") }
        }
        for case let item as URL in items { try apply(to: item) }
        if let enumerationError { throw enumerationError }
        try apply(to: stage)
    }

    private static func check(_ status: Int32, _ archive: OpaquePointer) throws {
        guard status != ARCHIVE_OK else { return }
        let error = archiveError(archive)
        let detail = error.message.lowercased()
        if detail.contains("encrypted") || detail.contains("encryption") || detail.contains("passphrase") {
            throw PasswordRequired(retry: false)
        }
        throw error
    }

    private static func archiveError(_ archive: OpaquePointer) -> ExtractionError {
        let message = archive_error_string(archive).map { String(cString: $0) }
        return ExtractionError(message: message ?? "The archive could not be read.")
    }

    private static func systemError(_ action: String) -> ExtractionError {
        let code = errno
        return ExtractionError(message: "\(action): \(String(cString: strerror(code))).")
    }
}

import Darwin
import Foundation

struct PasswordRequired: LocalizedError {
    let retry: Bool
    var errorDescription: String? {
        retry ? "The password was rejected. Try again." : "Password-protected archive. Enter the password to continue."
    }
}

enum ArchiveEngine {
    static func input(_ source: URL) throws -> URL {
        let name = source.lastPathComponent
        let prefix: String
        let suffix: String
        let width: Int
        if let match = name.range(of: #"(?i)\.(zip|7z)\.[0-9]{3,}$"#, options: .regularExpression) {
            let tail = name[match]
            width = tail.split(separator: ".").last?.count ?? 3
            prefix = String(name.dropLast(width))
            suffix = ""
        } else if let match = name.range(of: #"(?i)\.part[0-9]+\.rar$"#, options: .regularExpression) {
            width = name[match].count - ".part.rar".count
            prefix = String(name.dropLast(width + 4))
            suffix = String(name.suffix(4))
        } else {
            return source
        }

        let folder = source.deletingLastPathComponent()
        let widths = width > 3 ? [width, 3] : [width]
        for digits in widths {
            let first = prefix + String(repeating: "0", count: digits - 1) + "1" + suffix
            let url = folder.appendingPathComponent(first)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        throw ExtractionError(message: "Missing first volume for \(name). Put all volumes in the same folder.")
    }

    static func isVolume(_ source: URL) -> Bool {
        source.lastPathComponent.range(of: #"(?i)(\.(zip|7z)\.[0-9]{3,}|\.part[0-9]+\.rar)$"#,
                                       options: .regularExpression) != nil
    }

    static func archiveName(_ source: URL) -> String {
        let name = source.lastPathComponent
        return name.replacingOccurrences(of: #"(?i)(\.tar\.gz|\.part[0-9]+\.rar|\.(zip|7z)\.[0-9]{3,}|\.[^.]+)$"#,
                                         with: "", options: .regularExpression)
    }

    static func verify(_ source: URL, password: String?) throws -> URL {
        let archive = try input(source)
        let work = try makeWorkspace(in: FileManager.default.temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: work) }
        try run(["t", "--", archive.path], password: password, in: work, restrictedTo: work)
        return archive
    }

    static func run(_ arguments: [String], password: String?, in work: URL,
                    restrictedTo output: URL? = nil) throws {
        try Task.checkCancellation()
        let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("7zz")
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ExtractionError(message: "The bundled archive engine is missing.")
        }
        let settings = ["-sccUTF-8", "-bsp0", "-bso1", "-bse1", "-spd"]
        let command = [arguments[0]] + settings + arguments.dropFirst()
        let process = Process()
        if let output {
            let profile = """
                (version 1)
                (allow default)
                (deny network*)
                (deny file-write*)
                (allow file-write* (subpath (param "OUTPUT")))
                """
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-D", "OUTPUT=\(output.path)", "-p", profile, executable.path] + command
        } else {
            process.executableURL = executable
            process.arguments = command
        }
        process.currentDirectoryURL = work
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "en_US.UTF-8"]
        let input = Pipe()
        process.standardInput = input.fileHandleForReading
        if let password {
            guard Self.validPassword(password) else {
                throw ExtractionError(message: "Passwords must be single-line text up to 1,024 UTF-8 bytes.")
            }
            try input.fileHandleForWriting.write(contentsOf: Data((password + "\n").utf8))
        }
        try input.fileHandleForWriting.close()
        defer { try? input.fileHandleForReading.close() }

        let log = work.appendingPathComponent(".engine-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ExtractionError(message: "Could not create the archive engine log.")
        }
        defer { try? FileManager.default.removeItem(at: log) }
        let stream = try FileHandle(forUpdating: log)
        defer { try? stream.close() }
        process.standardOutput = stream
        process.standardError = stream
        try process.run()
        while process.isRunning && !Task.isCancelled { Thread.sleep(forTimeInterval: 0.035) }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        try Task.checkCancellation()
        guard process.terminationStatus != 0 else { return }

        let end = try stream.seekToEnd()
        try stream.seek(toOffset: end > 32_768 ? end - 32_768 : 0)
        let logText = String(decoding: try stream.read(upToCount: 32_768) ?? Data(), as: UTF8.self)
        if arguments[0] != "a" {
            let lines = logText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            if (password == nil && lines.contains("Enter password:"))
                || lines.contains(where: { $0.hasPrefix("ERROR: Wrong password") || $0.contains("Wrong password?") }) {
                throw PasswordRequired(retry: password != nil)
            }
        }
        let lines = logText.split(whereSeparator: \.isNewline)
        let useful = lines.filter {
            $0.contains("ERROR") || $0.contains("Error") || $0.contains("sandbox") || $0.hasPrefix("E_")
        }.prefix(3).joined(separator: "\n")
        let message = useful.isEmpty ? "Archive operation failed (code \(process.terminationStatus))." : useful
        throw ExtractionError(message: message)
    }

    static func validPassword(_ password: String) -> Bool {
        !password.isEmpty && password.utf8.count <= 1_024 && !password.contains(where: \.isNewline)
            && !password.utf8.contains(0)
    }

    static func makeWorkspace(in folder: URL) throws -> URL {
        guard let resolved = realpath(folder.path, nil) else {
            throw ExtractionError(message: "Could not find the destination folder.")
        }
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        let work = root.appendingPathComponent(".quietextract-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(work.path, 0o700) == 0 else {
            throw ExtractionError(message: "Could not create a temporary folder in \(folder.lastPathComponent).")
        }
        return work
    }

    static func publish(_ source: URL, in parent: URL, name: String, suffix: String = "") throws -> URL {
        for sequence in 1...10_000 {
            let stem = sequence == 1 ? name : "\(name) (\(sequence))"
            let output = parent.appendingPathComponent(stem + suffix)
            if renamex_np(source.path, output.path, UInt32(RENAME_EXCL)) == 0 { return output }
            if errno != EEXIST {
                throw ExtractionError(message: "Could not save the result: \(String(cString: strerror(errno))).")
            }
        }
        throw ExtractionError(message: "Could not find a free name for the result.")
    }
}

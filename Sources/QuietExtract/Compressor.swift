import Darwin
import Foundation

struct CompressionOptions: Sendable {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case zip, sevenZip = "7z"
        var id: Self { self }
        var label: String { self == .zip ? "ZIP" : "7z" }
    }

    let format: Format
    let level: Int
    let volumeBytes: Int64?
    let password: String?
    let aes: Bool
    let encryptNames: Bool
    let excludeResources: Bool
    let verify: Bool
    let separate: Bool
    let trashSources: Bool
    let name: String
    let destination: URL
}

enum Compressor {
    static func create(from sources: [URL], options: CompressionOptions) throws -> URL {
        guard !sources.isEmpty, validName(options.name) else {
            throw ExtractionError(message: "Choose files and enter a valid archive name.")
        }
        if let password = options.password, let error = passwordError(password, format: options.format) {
            throw ExtractionError(message: error)
        }
        if let bytes = options.volumeBytes, bytes < 32 * 1024 {
            throw ExtractionError(message: "Each volume must be at least 32 KiB.")
        }
        if options.excludeResources && sources.contains(where: {
            $0.lastPathComponent == ".DS_Store" || $0.lastPathComponent == "__MACOSX" || $0.lastPathComponent.hasPrefix("._")
        }) {
            throw ExtractionError(message: "An explicitly selected item is a Mac resource file. Deselect it or turn off resource exclusion.")
        }
        let work = try ArchiveEngine.makeWorkspace(in: options.destination)
        defer { try? FileManager.default.removeItem(at: work) }
        let canonical = sources.map { $0.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent($0.lastPathComponent) }
        var exclusions: Set<String> = [".DS_Store", "__MACOSX"]
        for source in canonical {
            exclusions.formUnion(try checkInput(source, work: work, excludeResources: options.excludeResources))
        }
        let exclusionList = work.appendingPathComponent("resource-names.txt")
        if options.excludeResources {
            try exclusions.sorted().joined(separator: "\n").write(to: exclusionList, atomically: true, encoding: .utf8)
        }
        let groups = options.separate ? canonical.map { [$0] } : [canonical]
        let result = work.appendingPathComponent("result", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])

        var firstArchive: URL?
        for group in groups {
            try Task.checkCancellation()
            let names = group.map { $0.lastPathComponent.lowercased().precomposedStringWithCanonicalMapping }
            guard Set(names).count == names.count else {
                throw ExtractionError(message: "Some selected items have the same name. Use separate archives.")
            }
            let name = options.separate ? group[0].lastPathComponent : options.name
            let archive = result.appendingPathComponent(name + "." + options.format.rawValue)
            let first = options.volumeBytes == nil ? archive : archive.appendingPathExtension("001")
            guard !FileManager.default.fileExists(atPath: first.path) else {
                throw ExtractionError(message: "Separate archives would have duplicate names.")
            }
            var arguments = ["a", "-t\(options.format.rawValue)", "-mx=\(options.level)"]
            if let bytes = options.volumeBytes { arguments.append("-v\(bytes)b") }
            if options.password != nil {
                arguments.append("-p")
                if options.format == .zip { arguments.append(options.aes ? "-mem=AES256" : "-mem=ZipCrypto") }
                if options.format == .sevenZip && options.encryptNames { arguments.append("-mhe=on") }
            }
            if options.excludeResources { arguments += ["-scsUTF-8", "-xr@\(exclusionList.path)"] }
            arguments += [archive.path, "--"] + group.map(\.path)
            try ArchiveEngine.run(arguments, password: options.password, in: work)
            if options.verify || options.trashSources {
                try ArchiveEngine.run(["t", "--", first.path], password: options.password, in: work)
            }
            firstArchive = first
        }
        try Task.checkCancellation()
        if options.volumeBytes != nil || options.separate {
            let name = options.separate ? options.name + " Archives" : options.name + "." + options.format.rawValue + " Parts"
            return try ArchiveEngine.publish(result, in: options.destination, name: name)
        }
        guard let firstArchive else { throw ExtractionError(message: "No archive was created.") }
        return try ArchiveEngine.publish(firstArchive, in: options.destination, name: options.name,
                                         suffix: "." + options.format.rawValue)
    }

    static func passwordError(_ password: String, format: CompressionOptions.Format) -> String? {
        if !ArchiveEngine.validPassword(password) {
            return "Use a single-line password up to 1,024 UTF-8 bytes."
        }
        if format == .zip && (password.utf8.count > 99 || !password.utf8.allSatisfy({ (32...126).contains($0) })) {
            return "ZIP passwords use up to 99 printable ASCII characters."
        }
        return nil
    }

    static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.utf8.contains(0) && !name.contains(where: \.isNewline)
    }

    private static func checkInput(_ source: URL, work: URL, excludeResources: Bool) throws -> Set<String> {
        func check(_ item: URL) throws -> Bool {
            try Task.checkCancellation()
            var info = stat()
            guard lstat(item.path, &info) == 0 else {
                throw ExtractionError(message: "Could not read \(item.lastPathComponent).")
            }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFDIR || kind == S_IFREG else {
                throw ExtractionError(message: "Links and special files cannot be compressed: \(item.lastPathComponent)")
            }
            return kind == S_IFDIR
        }
        guard try check(source) else { return [] }
        guard let path = realpath(source.path, nil) else {
            throw ExtractionError(message: "Could not resolve \(source.lastPathComponent).")
        }
        defer { free(path) }
        guard !work.path.hasPrefix(String(cString: path).trimmingSuffixSlash + "/") else {
            throw ExtractionError(message: "Choose a destination outside the selected folders.")
        }
        var scanError: Error?
        guard let files = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [],
            errorHandler: { _, error in scanError = error; return false }) else {
            throw ExtractionError(message: "Could not scan \(source.lastPathComponent).")
        }
        var excludedNames: Set<String> = []
        for case let item as URL in files {
            let name = item.lastPathComponent
            if excludeResources && (name == ".DS_Store" || name == "__MACOSX" || name.hasPrefix("._")) {
                guard !name.contains(where: \.isNewline) else {
                    throw ExtractionError(message: "An excluded resource filename contains a line break.")
                }
                excludedNames.insert(name)
                files.skipDescendants()
                continue
            }
            _ = try check(item)
        }
        if let scanError { throw scanError }
        return excludedNames
    }
}

private extension String {
    var trimmingSuffixSlash: String { hasSuffix("/") ? String(dropLast()) : self }
}

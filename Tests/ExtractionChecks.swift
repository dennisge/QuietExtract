import Darwin
import Foundation

@main
enum ExtractionChecks {
    static func main() throws {
        setlocale(LC_CTYPE, "en_US.UTF-8")
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let files = FileManager.default

        func extract(_ name: String) throws -> URL {
            try Extractor.extract(fixtures.appendingPathComponent(name))
        }

        func expectFile(_ path: String, in directory: URL, contents: Data) throws {
            let actual = try Data(contentsOf: directory.appendingPathComponent(path))
            precondition(actual == contents, "Unexpected contents: \(path)")
        }

        func expectRejection(_ file: String, contains message: String) throws {
            do {
                _ = try extract(file)
                preconditionFailure("Unexpectedly extracted \(file)")
            } catch {
                precondition(error.localizedDescription.localizedCaseInsensitiveContains(message),
                             "\(file): \(error.localizedDescription)")
            }
        }

        let payload = Data("QuietExtract test\n".utf8)
        let zip = try extract("unicode.zip")
        try expectFile("資料/測試.txt", in: zip, contents: payload)
        let zipAgain = try extract("unicode.zip")
        precondition(zipAgain.lastPathComponent == "unicode (2)")
        try expectFile("資料/測試.txt", in: zip, contents: payload)
        print("PASS ZIP, Unicode paths, and collision-safe naming")

        let sevenZip = try extract("seven.7z")
        try expectFile("payload.txt", in: sevenZip, contents: payload)
        print("PASS 7z")

        let gzipTar = try extract("bundle.tar.gz")
        precondition(gzipTar.lastPathComponent == "bundle")
        try expectFile("payload.txt", in: gzipTar, contents: payload)
        print("PASS tar.gz")

        let stored = try extract("rar5-stored.rar")
        try expectFile("helloworld.txt", in: stored, contents: Data("hello libarchive test suite!\n".utf8))
        let compressed = try extract("rar5-compressed.rar")
        let expected = try Data(contentsOf: fixtures.appendingPathComponent("expected-rar.bin"))
        try expectFile("test.bin", in: compressed, contents: expected)
        print("PASS RAR5 stored and compressed")

        let empty = try extract("empty.zip")
        let emptyContents = try files.contentsOfDirectory(atPath: empty.path)
        precondition(emptyContents.isEmpty)
        let selfNamed = try extract("only.zip")
        precondition(selfNamed.lastPathComponent == "only (2)")
        print("PASS empty ZIP and existing output symlink")

        try expectRejection("traversal.zip", contains: "Unsafe path")
        try expectRejection("absolute.zip", contains: "Unsafe path")
        try expectRejection("links.tar.gz", contains: "Links and special files")
        try expectRejection("duplicate.zip", contains: "Duplicate path")
        try expectRejection("corrupt.zip", contains: "CRC")
        try expectRejection("password.zip", contains: "Password-protected")
        let names = try files.contentsOfDirectory(atPath: fixtures.path)
        for name in ["traversal", "absolute", "links", "duplicate", "corrupt", "password", "escape.txt"] {
            precondition(!names.contains(name), "Unexpected published output: \(name)")
        }
        precondition(!names.contains { $0.hasPrefix(".quietextract-") })
        print("PASS unsafe path, link, duplicate, damaged and encrypted archive rejection and cleanup")

        let quarantined = fixtures.appendingPathComponent("quarantined.zip")
        let quarantine = Array("0081;00000000;QuietExtractTests;".utf8)
        let attribute = "com.apple.quarantine"
        let write = quarantine.withUnsafeBytes {
            setxattr(quarantined.path, attribute, $0.baseAddress, $0.count, 0, 0)
        }
        precondition(write == 0)
        let result = try extract("quarantined.zip")
        for path in [result.path, result.appendingPathComponent("payload.txt").path] {
            var bytes = [UInt8](repeating: 0, count: 1024)
            let length = bytes.withUnsafeMutableBytes {
                getxattr(path, attribute, $0.baseAddress, $0.count, 0, 0)
            }
            precondition(length == quarantine.count && bytes.prefix(length).elementsEqual(quarantine))
        }
        print("PASS download quarantine propagation")
        try checkArchiveTools(in: fixtures, payload: payload)
    }

    private static func checkArchiveTools(in fixtures: URL, payload: Data) throws {
        let files = FileManager.default
        let password = "local-test-2026"
        func path(_ name: String) -> URL { fixtures.appendingPathComponent(name) }

        func expectPassword(retry: Bool, _ operation: () throws -> URL) throws {
            do {
                _ = try operation()
                preconditionFailure("Expected a password request")
            } catch let error as PasswordRequired {
                precondition(error.retry == retry)
            }
        }

        func settings(_ name: String, format: CompressionOptions.Format = .zip,
                      password: String? = nil, split: Bool = false, separate: Bool = false) -> CompressionOptions {
            CompressionOptions(format: format, level: split ? 0 : 5, volumeBytes: split ? 32 * 1024 : nil,
                               password: password, aes: true, encryptNames: true, excludeResources: true,
                               verify: true, separate: separate, trashSources: false, name: name, destination: fixtures)
        }

        func expectBytes(_ file: URL, _ expected: Data) throws {
            let actual = try Data(contentsOf: file)
            precondition(actual == expected, "Unexpected contents: \(file.path)")
        }

        let source = path("Example")
        try files.createDirectory(at: source, withIntermediateDirectories: false)
        try payload.write(to: source.appendingPathComponent("測試[1].txt"))
        for name in [".DS_Store", "._測試[1].txt"] {
            try payload.write(to: source.appendingPathComponent(name))
        }
        let zip = try Compressor.create(from: [source], options: settings("aes", password: password))
        try expectPassword(retry: false) { try Extractor.extract(zip) }
        try expectPassword(retry: true) { try Extractor.extract(zip, password: "wrong") }
        try expectPassword(retry: false) { try ArchiveEngine.verify(zip, password: nil) }
        try expectPassword(retry: true) { try ArchiveEngine.verify(zip, password: "wrong") }
        let unlocked = try Extractor.extract(zip, password: password)
        let extracted = unlocked.appendingPathComponent("Example")
        let entries = try files.contentsOfDirectory(atPath: extracted.path)
        precondition(entries == ["測試[1].txt"], "Unexpected resource entries: \(entries)")
        try expectBytes(extracted.appendingPathComponent("測試[1].txt"), payload)
        _ = try ArchiveEngine.verify(zip, password: password)
        let zipAgain = try Compressor.create(from: [source], options: settings("aes", password: password))
        precondition(zipAgain.lastPathComponent == "aes (2).zip")
        print("PASS AES ZIP, Unicode filename, wrong password retry, resource exclusion and collision-safe creation")

        let legacy = path("password.zip")
        let legacyUnlocked = try Extractor.extract(legacy, password: "test-fixture-password")
        try expectBytes(legacyUnlocked.appendingPathComponent("payload.txt"), payload)

        let rar = path("rar5-encrypted-filenames.rar")
        try expectPassword(retry: false) { try Extractor.extract(rar) }
        try expectPassword(retry: true) { try Extractor.extract(rar, password: "wrong") }
        let rarUnlocked = try Extractor.extract(rar, password: "password")
        let rarEntries = try files.contentsOfDirectory(atPath: rarUnlocked.path).sorted()
        precondition(rarEntries == ["a.txt", "b.txt", "c.txt", "d.txt"])
        try expectBytes(rarUnlocked.appendingPathComponent("a.txt"), Data("This is from a.txt".utf8))
        _ = try ArchiveEngine.verify(rar, password: "password")
        print("PASS ZipCrypto and RAR5 with encrypted filenames")

        let blob = Data(repeating: 0x61, count: 110_000)
        let big = path("big.bin")
        try blob.write(to: big)
        for format in CompressionOptions.Format.allCases {
            let password = format == .zip ? password : "local-test-密碼-2026"
            let folder = try Compressor.create(from: [big], options: settings("split", format: format,
                                                                               password: password, split: true))
            let prefix = "split." + format.rawValue
            let first = folder.appendingPathComponent(prefix + ".001")
            let second = folder.appendingPathComponent(prefix + ".002")
            let third = folder.appendingPathComponent(prefix + ".003")
            precondition(files.fileExists(atPath: third.path))
            let verified = try ArchiveEngine.verify(third, password: password)
            precondition(verified == first)
            try expectPassword(retry: false) { try Extractor.extract(second) }
            try expectPassword(retry: true) { try Extractor.extract(second, password: "wrong") }
            let output = try Extractor.extract(second, password: password)
            try expectBytes(output.appendingPathComponent("big.bin"), blob)

            let hidden = folder.appendingPathComponent("hidden")
            try files.moveItem(at: second, to: hidden)
            do {
                _ = try ArchiveEngine.verify(first, password: password)
                preconditionFailure("Verified an archive with a missing middle volume")
            } catch is ExtractionError {}
            do {
                _ = try Extractor.extract(first, password: password)
                preconditionFailure("Extracted an archive with a missing middle volume")
            } catch is ExtractionError {}
            try files.moveItem(at: hidden, to: second)
            print("PASS encrypted \(format.label) volumes, later volume selection and missing volume rejection")
        }

        let separate = try Compressor.create(from: [source, big], options: settings("Separate", separate: true))
        let separateEntries = try files.contentsOfDirectory(atPath: separate.path).sorted()
        precondition(separateEntries == ["Example.zip", "big.bin.zip"])
        for name in ["unicode.zip", "rar5-compressed.rar", "seven.7z", "bundle.tar.gz"] {
            _ = try ArchiveEngine.verify(path(name), password: nil)
        }
        do {
            _ = try ArchiveEngine.verify(path("corrupt.zip"), password: nil)
            preconditionFailure("Verified a damaged ZIP")
        } catch is ExtractionError {}
        print("PASS separate archives, standalone integrity checks and corrupt ZIP rejection")
    }
}

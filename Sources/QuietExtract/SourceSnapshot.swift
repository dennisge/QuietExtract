import Darwin
import Foundation

enum SourceSnapshot {
    struct Stamp: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modified: Int
        let modifiedNS: Int
        let changed: Int
        let changedNS: Int
    }

    static func read(_ files: [URL]) throws -> [String: Stamp] {
        var result: [String: Stamp] = [:]
        func record(_ url: URL) throws -> Bool {
            try Task.checkCancellation()
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                throw ExtractionError(message: "Could not check the identity of \(url.lastPathComponent).")
            }
            result[url.path] = Stamp(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                modified: info.st_mtimespec.tv_sec, modifiedNS: info.st_mtimespec.tv_nsec,
                changed: info.st_ctimespec.tv_sec, changedNS: info.st_ctimespec.tv_nsec)
            return (info.st_mode & S_IFMT) == S_IFDIR
        }
        for file in files where try record(file) {
            var scanError: Error?
            guard let contents = FileManager.default.enumerator(at: file, includingPropertiesForKeys: [],
                errorHandler: { _, error in scanError = error; return false }) else {
                throw ExtractionError(message: "Could not scan \(file.lastPathComponent).")
            }
            for case let entry as URL in contents { _ = try record(entry) }
            if let scanError { throw scanError }
        }
        return result
    }
}

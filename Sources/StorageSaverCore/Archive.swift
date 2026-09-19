import Foundation

public enum ArchiveError: Error, CustomStringConvertible {
    case copyFailed(String, String)
    case mismatch(String)
    case samePath(String)
    public var description: String {
        switch self {
        case .copyFailed(let src, let why): return "archive copy failed for \(src): \(why)"
        case .mismatch(let p): return "archive copy does not match the original: \(p)"
        case .samePath(let p): return "archive destination is the original file itself: \(p)"
        }
    }
}

/// Copies a file into the archive tree, fsyncs it, and verifies the bytes
/// before the caller is allowed to remove the original.
public enum Archive {
    public static func destination(for candidatePath: String, store: MessagesStore, archiveRoot: URL) -> URL {
        let base = store.attachmentsDir.path + "/"
        let rel = candidatePath.hasPrefix(base) ? String(candidatePath.dropFirst(base.count)) : (candidatePath as NSString).lastPathComponent
        return archiveRoot.appendingPathComponent("Attachments").appendingPathComponent(rel)
    }

    /// Returns the archive path on success. Copies to a `.partial` name, fsyncs,
    /// verifies, then renames into place (rename replaces atomically, so no
    /// separate delete is ever needed, even for a stale partial copy).
    public static func copyVerified(from source: String, to destination: URL) throws -> String {
        let fm = FileManager.default
        // An archive root inside the store would make source == destination:
        // "identical" would be trivially true and the only copy then unlinked.
        let sourceReal = URL(fileURLWithPath: source).resolvingSymlinksInPath().standardizedFileURL.path
        let destinationReal = destination.resolvingSymlinksInPath().standardizedFileURL.path
        guard sourceReal != destinationReal else { throw ArchiveError.samePath(source) }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path), try filesAreIdentical(source, destination.path) {
            return destination.path
        }
        let partial = destination.path + ".partial"
        do { try fm.copyItem(atPath: source, toPath: partial) } catch {
            throw ArchiveError.copyFailed(source, "\(error)")
        }
        if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: partial)) { try? h.synchronize(); try? h.close() }
        guard try filesAreIdentical(source, partial) else { throw ArchiveError.mismatch(partial) }
        guard rename(partial, destination.path) == 0 else { throw ArchiveError.copyFailed(source, "rename failed: \(String(cString: strerror(errno)))") }
        return destination.path
    }

    public static func filesAreIdentical(_ a: String, _ b: String) throws -> Bool {
        let fa = try FileHandle(forReadingFrom: URL(fileURLWithPath: a))
        let fb = try FileHandle(forReadingFrom: URL(fileURLWithPath: b))
        defer { try? fa.close(); try? fb.close() }
        let chunk = 4 * 1024 * 1024
        while true {
            let da = try fa.read(upToCount: chunk) ?? Data()
            let db = try fb.read(upToCount: chunk) ?? Data()
            if da != db { return false }
            if da.isEmpty { return true }
        }
    }
}

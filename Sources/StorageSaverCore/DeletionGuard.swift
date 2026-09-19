import Foundation
import Darwin

public enum GuardError: Error, CustomStringConvertible {
    case notApproved(String)
    case notRegularFile(String)
    case outsideRoot(String)
    case looksLikeDatabase(String)
    case unlinkFailed(String, Int32)

    public var description: String {
        switch self {
        case .notApproved(let p): return "refusing to remove a path this run did not select: \(p)"
        case .notRegularFile(let p): return "refusing to remove a non-regular file (directory, symlink, ...): \(p)"
        case .outsideRoot(let p): return "refusing to remove a path outside the allowed tree: \(p)"
        case .looksLikeDatabase(let p): return "refusing to remove a database file: \(p)"
        case .unlinkFailed(let p, let e): return "unlink failed for \(p): \(String(cString: strerror(e)))"
        }
    }
}

/// The only code path in this package that removes anything. It calls
/// `unlink(2)` on a single regular file that (a) was approved by the current
/// run, (b) really lives under the allowed tree, and (c) is not a database.
/// It cannot remove directories: `unlink` refuses them.
public final class DeletionGuard {
    public enum Root: String {
        case attachments
        case previews
    }

    private let store: MessagesStore
    private var approved: Set<String>
    public private(set) var removedFiles = 0
    public private(set) var removedBytes: Int64 = 0

    public init(store: MessagesStore, approvedPaths: [String]) {
        self.store = store
        self.approved = Set(approvedPaths)
    }

    public func approve(_ paths: [String]) { approved.formUnion(paths) }

    private func rootURL(_ root: Root) -> URL {
        switch root {
        case .attachments: return store.attachmentsDir
        case .previews: return store.previewsDir
        }
    }

    /// Removes `path`. Returns the size of the removed file. When
    /// `expectedSize` is given the file must still have exactly that size.
    @discardableResult
    public func unlink(_ path: String, root: Root, expectedSize: Int64? = nil) throws -> Int64 {
        guard approved.contains(path) else { throw GuardError.notApproved(path) }
        let name = (path as NSString).lastPathComponent.lowercased()
        if name.hasSuffix(".db") || name.contains(".db-") || name.hasSuffix(".sqlite") || name.contains(".sqlite-") {
            throw GuardError.looksLikeDatabase(path)
        }
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw GuardError.notRegularFile(path) }
        if let expectedSize, Int64(st.st_size) != expectedSize { throw GuardError.notRegularFile(path + " (size changed since selection)") }
        let base = rootURL(root).resolvingSymlinksInPath().path
        let parentReal = URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath().path
        guard (parentReal + "/" + (path as NSString).lastPathComponent).hasPrefix(base + "/") else { throw GuardError.outsideRoot(path) }
        guard Darwin.unlink(path) == 0 else { throw GuardError.unlinkFailed(path, errno) }
        removedFiles += 1
        removedBytes += Int64(st.st_size)
        return Int64(st.st_size)
    }
}

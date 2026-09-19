import Foundation
import Darwin

public enum LockError: Error, CustomStringConvertible {
    case busy(String)
    case cannotCreate(String)
    public var description: String {
        switch self {
        case .busy(let p): return "another run holds \(p)"
        case .cannotCreate(let p): return "cannot create lock file \(p)"
        }
    }
}

/// Single-instance lock (flock). Released when the object is deallocated.
public final class RunLock {
    private let fd: Int32
    public let url: URL

    public static var defaultURL: URL { Policy.supportDirectory.appendingPathComponent("run.lock") }

    public init(url: URL = RunLock.defaultURL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw LockError.cannotCreate(url.path) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw LockError.busy(url.path)
        }
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

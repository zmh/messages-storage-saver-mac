import Foundation
import Darwin

/// What is known about an archive folder before a run relies on it.
public struct ArchiveCheck: Codable, Equatable {
    public var path: String
    /// The folder exists, or can be created under an existing parent that is
    /// not a bare mount point.
    public var reachable: Bool
    public var writable: Bool
    /// nil when unreachable. Same volume as the store means the copy is an
    /// APFS clone that shares blocks: removing the original frees nothing.
    public var sameVolumeAsStore: Bool?
    public var insideStore: Bool
    public var insideLibrary: Bool
    public var detail: String
    /// Non-nil means real runs must refuse.
    public var blocker: String?
    public var warning: String? {
        sameVolumeAsStore == true ? "archive is on the same disk as the Messages store: removing the originals frees no space until the archive is moved or deleted" : nil
    }
}

public enum ArchiveLocation {
    /// `st_dev` of `path`, or nil if it does not exist.
    public static func deviceID(of path: String) -> UInt64? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return UInt64(st.st_dev)
    }

    /// Nearest existing ancestor of `url` (the path itself if it exists).
    static func nearestExisting(_ url: URL) -> URL {
        var u = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: u.path), u.path != "/" {
            u = u.deletingLastPathComponent()
        }
        return u
    }

    public static func check(_ archive: URL, store: MessagesStore) -> ArchiveCheck {
        let path = archive.standardizedFileURL.path
        let storeRoot = store.root.standardizedFileURL.path
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").standardizedFileURL.path
        let insideStore = path == storeRoot || path.hasPrefix(storeRoot + "/")
        let insideLibrary = store.isLive && (path == library || path.hasPrefix(library + "/"))

        let existing = nearestExisting(archive)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        // /Volumes/<name> absent means the disk is not mounted; creating a
        // folder under /Volumes itself would silently land on the boot disk.
        let unmounted = existing.path == "/Volumes" && path.hasPrefix("/Volumes/")
        let reachable = !unmounted && (!exists || isDir.boolValue)
        let writable = reachable && access(existing.path, W_OK) == 0
        let sameVolume: Bool? = reachable ? (deviceID(of: existing.path) == deviceID(of: storeRoot)) : nil

        var blocker: String?
        if insideStore {
            blocker = "archive folder must not be inside the Messages store"
        } else if insideLibrary {
            blocker = "archive folder must not be inside ~/Library; choose a visible folder or an external disk"
        } else if unmounted {
            blocker = "archive volume is not mounted (\(existing.path == "/Volumes" ? path : existing.path))"
        } else if exists && !isDir.boolValue {
            blocker = "archive path exists but is not a folder"
        } else if !writable {
            blocker = "archive folder is not writable (\(existing.path))"
        }

        var detail: String
        if let blocker {
            detail = blocker
        } else if sameVolume == true {
            detail = "WARNING: " + (exists ? "exists" : "will be created") + ", but it is on the same disk as the Messages store, so removing originals frees no space"
        } else {
            detail = (exists ? "exists" : "will be created") + " on a different disk than the Messages store"
        }
        return ArchiveCheck(path: path, reachable: reachable, writable: writable, sameVolumeAsStore: sameVolume,
                            insideStore: insideStore, insideLibrary: insideLibrary, detail: detail, blocker: blocker)
    }
}

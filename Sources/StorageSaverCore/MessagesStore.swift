import Foundation

/// Paths of a Messages store. The live store is `~/Library/Messages`; tests
/// and development use a synthetic store built by `scripts/make-fixture.py`.
public struct MessagesStore: Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public static var live: MessagesStore {
        MessagesStore(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages"))
    }

    public enum AccessError: Error, CustomStringConvertible {
        case debugBuildNeedsFixture
        public var description: String {
            "Debug builds only touch the live Messages store with MSS_ALLOW_REAL_STORE=1; point the tool at a fixture store instead."
        }
    }

    /// The live store, except that debug builds refuse it unless the caller
    /// opted in through the environment. Development and tests run against
    /// fixtures; only release builds default to `~/Library/Messages`.
    public static func liveChecked(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> MessagesStore {
        #if DEBUG
        guard environment["MSS_ALLOW_REAL_STORE"] == "1" else { throw AccessError.debugBuildNeedsFixture }
        #endif
        return .live
    }

    public var chatDB: URL { root.appendingPathComponent("chat.db") }
    public var attachmentsDir: URL { root.appendingPathComponent("Attachments") }
    public var previewsDir: URL { root.appendingPathComponent("Caches/Previews/Attachments") }
    public var syncDir: URL { root.appendingPathComponent("Sync") }

    public var isLive: Bool { root.path == MessagesStore.live.root.path }

    /// Where this store's journal, lock and canary baseline live. The live
    /// store uses Application Support; any other store (fixtures, copies)
    /// keeps its bookkeeping next to itself so tests can never pollute the
    /// live records.
    public var supportDirectory: URL {
        isLive ? Policy.supportDirectory : root.appendingPathComponent(".messages-storage-saver")
    }
    public var journalURL: URL { supportDirectory.appendingPathComponent("journal.jsonl") }
    public var lockURL: URL { supportDirectory.appendingPathComponent("run.lock") }
    public var baselineURL: URL { supportDirectory.appendingPathComponent("baseline.json") }
    /// Same as `Policy.configURL` for the live store; fixture stores keep
    /// their config next to their journal so tests never touch the real one.
    public var configURL: URL { supportDirectory.appendingPathComponent("config.json") }

    /// The prefix Messages writes into `attachment.filename`.
    static let tildePrefix = "~/Library/Messages/Attachments/"

    /// Maps a database `filename` onto this store's Attachments tree.
    /// Returns nil for anything outside the tree (e.g. `/var/folders/...`,
    /// sticker caches, containers), which is never eligible.
    public func resolve(dbFilename: String) -> URL? {
        if dbFilename.hasPrefix(Self.tildePrefix) {
            return attachmentsDir.appendingPathComponent(String(dbFilename.dropFirst(Self.tildePrefix.count)))
        }
        let absolutePrefix = MessagesStore.live.attachmentsDir.path + "/"
        if dbFilename.hasPrefix(absolutePrefix) {
            return attachmentsDir.appendingPathComponent(String(dbFilename.dropFirst(absolutePrefix.count)))
        }
        return nil
    }

    /// True when `url`'s real path is inside this store's Attachments tree.
    /// Symlinks are not followed for the final component: a symlink whose
    /// target is outside the tree fails this check.
    public func containsInAttachments(_ url: URL) -> Bool {
        let base = attachmentsDir.resolvingSymlinksInPath().path
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        let candidate = parent + "/" + url.lastPathComponent
        return candidate.hasPrefix(base + "/")
    }
}

import Foundation
import StorageSaverCore

/// Which Messages store the app works on. Development and tests point at a
/// fixture through `MSS_APP_STORE_DIR`; debug builds refuse the live store
/// unless `MSS_ALLOW_REAL_STORE=1`; release builds use `~/Library/Messages`.
public enum StoreResolver {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case debugBuildNeedsFixture
        case fixtureMissing(String)
        public var description: String {
            switch self {
            case .debugBuildNeedsFixture:
                return "This is a debug build. Set MSS_APP_STORE_DIR to a fixture store, or MSS_ALLOW_REAL_STORE=1 to use the live Messages store."
            case .fixtureMissing(let p):
                return "MSS_APP_STORE_DIR points at \(p), which has no chat.db."
            }
        }
    }

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> MessagesStore {
        if let dir = environment["MSS_APP_STORE_DIR"], !dir.isEmpty {
            let store = MessagesStore(root: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath))
            guard FileManager.default.fileExists(atPath: store.chatDB.path) else { throw Failure.fixtureMissing(store.root.path) }
            return store
        }
        do {
            return try MessagesStore.liveChecked(environment: environment)
        } catch {
            throw Failure.debugBuildNeedsFixture
        }
    }
}

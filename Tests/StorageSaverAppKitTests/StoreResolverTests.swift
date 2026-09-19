import Foundation
import XCTest
import StorageSaverCore
@testable import StorageSaverAppKit

final class StoreResolverTests: XCTestCase {
    func testDebugBuildRefusesLiveStoreWithoutEnv() {
        XCTAssertThrowsError(try StoreResolver.resolve(environment: [:])) {
            XCTAssertEqual($0 as? StoreResolver.Failure, .debugBuildNeedsFixture)
        }
    }

    func testOptInSelectsLiveStore() throws {
        XCTAssertEqual(try StoreResolver.resolve(environment: ["MSS_ALLOW_REAL_STORE": "1"]).root, MessagesStore.live.root)
    }

    func testFixtureEnvSelectsFixtureAndMustContainADatabase() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("mss-nostore-\(UUID().uuidString)")
        XCTAssertThrowsError(try StoreResolver.resolve(environment: ["MSS_APP_STORE_DIR": missing.path]))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mss-appkit-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("chat.db").path, contents: Data())
        let store = try StoreResolver.resolve(environment: ["MSS_APP_STORE_DIR": dir.path])
        XCTAssertEqual(store.root, dir.standardizedFileURL)
        XCTAssertFalse(store.isLive)
    }
}

import Foundation
import XCTest
@testable import StorageSaverCore

/// Builds the synthetic store from scripts/make-fixture.py once per process.
enum Fixture {
    static let packageRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url = url.deletingLastPathComponent() }
        return url
    }()

    static let store: MessagesStore = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mss-fixture-\(ProcessInfo.processInfo.processIdentifier)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [packageRoot.appendingPathComponent("scripts/make-fixture.py").path, dir.path]
        try! p.run()
        p.waitUntilExit()
        precondition(p.terminationStatus == 0, "fixture build failed")
        return MessagesStore(root: dir)
    }()
}

final class ReadOnlyDatabaseTests: XCTestCase {
    func testSchemaVerifies() throws {
        let db = try ReadOnlyDatabase(path: Fixture.store.chatDB.path)
        XCTAssertNoThrow(try db.verifySchema())
    }

    func testAuthorizerDeniesInsert() throws {
        let db = try ReadOnlyDatabase(path: Fixture.store.chatDB.path)
        XCTAssertThrowsError(try db.query("INSERT INTO sync_deleted_attachments (guid) VALUES ('x')")) { error in
            XCTAssertTrue("\(error)".contains("not authorized") || "\(error)".contains("readonly"), "\(error)")
        }
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sync_deleted_attachments"), 1)
    }

    func testAuthorizerDeniesDeleteUpdateAndPragmaWrites() throws {
        let db = try ReadOnlyDatabase(path: Fixture.store.chatDB.path)
        XCTAssertThrowsError(try db.query("DELETE FROM attachment"))
        XCTAssertThrowsError(try db.query("UPDATE attachment SET transfer_state = 0"))
        XCTAssertThrowsError(try db.query("PRAGMA journal_mode = DELETE"))
        XCTAssertThrowsError(try db.query("CREATE TABLE x (a)"))
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM attachment"), 23)
    }

    func testMissingSchemaIsRefused() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString).db")
        FileManager.default.createFile(atPath: tmp.path, contents: Data())
        let db = try ReadOnlyDatabase(path: tmp.path)
        XCTAssertThrowsError(try db.verifySchema())
    }
}

final class CandidateSelectionTests: XCTestCase {
    func labels(_ s: Selection) -> Set<String> { Set(s.candidates.map { $0.guid.replacingOccurrences(of: "att-", with: "") }) }

    func testKeepDays30SelectsExactlyTheEligibleOldFiles() throws {
        let db = try ReadOnlyDatabase(path: Fixture.store.chatDB.path)
        let s = try CandidateSelector.select(db: db, store: Fixture.store, policy: Policy())
        XCTAssertEqual(labels(s), [
            "eligible_old_jpeg", "eligible_old_heic_with_live_sidecar", "eligible_old_video",
            "boundary_31_days", "pinned_chat_old", "group_chat_old",
        ])
        XCTAssertEqual(Set(s.rejections.map { $0.reason.split(separator: " ").first.map(String.init) ?? "" }), ["missing", "size", "message"])
        XCTAssertEqual(s.skippedRecent, 2, "5-day and 29-day files stay")
        // Oldest first.
        XCTAssertEqual(s.candidates.first?.guid, "att-eligible_old_video")
    }

    func testPinnedChatIsNeverSelected() throws {
        let db = try ReadOnlyDatabase(path: Fixture.store.chatDB.path)
        var p = Policy()
        p.pinnedChats = ["Pinned Chat"]
        let s = try CandidateSelector.select(db: db, store: Fixture.store, policy: p)
        XCTAssertFalse(labels(s).contains("pinned_chat_old"))
        XCTAssertFalse(labels(s).contains("boundary_31_days"), "shared with the pinned chat")
        XCTAssertEqual(s.skippedPinned, 2)
        p.pinnedChats = ["iMessage;-;+15550000002"]
        XCTAssertFalse(labels(try CandidateSelector.select(db: db, store: Fixture.store, policy: p)).contains("pinned_chat_old"))
    }

    func testFreeSpaceTargetStopsWhenSatisfied() throws {
        let db = try ReadOnlyDatabase(path: Fixture.store.chatDB.path)
        var p = Policy()
        p.mode = .freeSpaceTarget
        p.targetFreeBytes = 4_000_000
        let s = try CandidateSelector.select(db: db, store: Fixture.store, policy: p, freeBytesNow: 0)
        XCTAssertEqual(labels(s), ["eligible_old_video"], "the oldest file alone satisfies the target")
        XCTAssertGreaterThan(s.skippedBudget, 0)
    }

    func testRunBudgetIsRespected() throws {
        let db = try ReadOnlyDatabase(path: Fixture.store.chatDB.path)
        let s = try CandidateSelector.select(db: db, store: Fixture.store, policy: Policy(), budgetBytes: 5_000_000)
        XCTAssertLessThanOrEqual(s.totalBytes, 5_000_000)
        XCTAssertFalse(labels(s).contains("eligible_old_video"))
        XCTAssertGreaterThan(s.skippedBudget, 0)
    }

    func testEverythingIsRecentWhenKeepDaysIsHuge() throws {
        let db = try ReadOnlyDatabase(path: Fixture.store.chatDB.path)
        var p = Policy()
        p.keepDays = 10_000
        let s = try CandidateSelector.select(db: db, store: Fixture.store, policy: p)
        XCTAssertTrue(s.candidates.isEmpty)
    }

    func testSymlinkInsideStoreIsNeverAContainedPath() {
        let link = Fixture.store.attachmentsDir.appendingPathComponent("cc/dd/att-symlink/escape.jpeg")
        XCTAssertFalse(Fixture.store.containsInAttachments(link.resolvingSymlinksInPath()))
        XCTAssertTrue(Fixture.store.containsInAttachments(link), "the link itself lives inside; lstat check catches the symlink")
    }
}

final class AnalysisTests: XCTestCase {
    func testAnalysisCountsTiersAndOrphans() throws {
        let report = try Analyzer.run(store: Fixture.store, policy: Policy())
        XCTAssertEqual(report.attachmentRows, 23)
        XCTAssertEqual(report.symlinksSkipped, 1)
        XCTAssertEqual(report.unreferencedLiveSidecars, 1)
        XCTAssertEqual(report.unreferencedFiles, 1, "only the sidecar; GroupPhotoImage is referenced by an orphan row")
        XCTAssertEqual(report.purgedShapeRows, 1)
        XCTAssertEqual(report.tombstoneAttachments, 1)
        XCTAssertEqual(report.candidateCount, 6)
        XCTAssertGreaterThan(report.previewCacheFiles, 0)
        XCTAssertFalse(report.render().isEmpty)
    }
}

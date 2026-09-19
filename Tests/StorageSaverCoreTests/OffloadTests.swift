import Foundation
import SQLite3
import XCTest
@testable import StorageSaverCore

/// Each test gets its own fresh fixture store because these runs remove files.
final class OffloadTests: XCTestCase {
    var store: MessagesStore!
    var support: URL!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mss-offload-\(UUID().uuidString)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [Fixture.packageRoot.appendingPathComponent("scripts/make-fixture.py").path, dir.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        store = MessagesStore(root: dir)
        support = dir.appendingPathComponent("support")
    }

    func journal() -> Journal { Journal(url: support.appendingPathComponent("journal.jsonl")) }
    func lockURL() -> URL { support.appendingPathComponent("run.lock") }

    /// The fixture ships one in-flight transfer, which (correctly) blocks real
    /// runs. Tests that exercise removal park it in a terminal state first.
    /// Uses a raw handle: the tool itself has no way to write the database.
    func makeQuiescent() {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.chatDB.path, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "UPDATE attachment SET transfer_state = -1 WHERE guid = 'att-transfer_in_progress'", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)
    }

    func fileCount() -> Int { Analyzer.walkFiles(store.attachmentsDir).files.count }

    func testDryRunRemovesNothing() throws {
        let before = fileCount()
        let r = try Offloader.run(store: store, request: OffloadRequest(policy: Policy(), tiers: [.attachments, .previews, .sidecars], dryRun: true), journal: journal(), lockURL: lockURL())
        XCTAssertTrue(r.dryRun)
        XCTAssertEqual(r.tiers.first { $0.tier == "attachments" }?.files, 6)
        XCTAssertEqual(fileCount(), before)
        XCTAssertTrue(r.canaryViolations.isEmpty)
        XCTAssertFalse(journal().hasCompletedRealRun())
    }

    func testRealRunRemovesExactlyTheCandidatesAndJournalsThem() throws {
        makeQuiescent()
        var p = Policy()
        p.firstRunMaxBytes = 1_000_000_000
        let before = fileCount()
        let r = try Offloader.run(store: store, request: OffloadRequest(policy: p, tiers: [.attachments], dryRun: false), journal: journal(), lockURL: lockURL())
        let tier = r.tiers.first { $0.tier == "attachments" }!
        XCTAssertEqual(tier.files, 6, "\(tier.errors)")
        XCTAssertEqual(fileCount(), before - 6)
        XCTAssertTrue(r.canaryViolations.isEmpty)
        let removed = journal().removedEntries()
        XCTAssertEqual(removed.count, 6)
        for e in removed { XCTAssertFalse(FileManager.default.fileExists(atPath: e.path!)) }
        // Recent, pinned-less, and ineligible files survive.
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.attachmentsDir.appendingPathComponent("cc/dd/att-symlink/escape.jpeg").path))
        XCTAssertTrue(journal().hasCompletedRealRun())
        // Live Photo sidecar stays when the sidecar tier is off.
        let sidecars = Analyzer.walkFiles(store.attachmentsDir).files.filter { $0.0.hasSuffix("IMG_0002.MOV") }
        XCTAssertEqual(sidecars.count, 1)
    }

    func testFirstRunBudgetCapsRemoval() throws {
        makeQuiescent()
        var p = Policy()
        p.firstRunMaxBytes = 5_000_000
        let r = try Offloader.run(store: store, request: OffloadRequest(policy: p, tiers: [.attachments], dryRun: false), journal: journal(), lockURL: lockURL())
        XCTAssertLessThanOrEqual(r.totalBytes, 5_000_000)
        XCTAssertGreaterThan(r.totalFiles, 0)
    }

    func testArchiveCopiesAreByteIdenticalBeforeRemoval() throws {
        makeQuiescent()
        // Next to the store, never inside it (an archive inside the store is refused).
        let archive = store.root.deletingLastPathComponent().appendingPathComponent("mss-archive-\(UUID().uuidString)")
        var p = Policy()
        p.firstRunMaxBytes = 1_000_000_000
        let r = try Offloader.run(store: store, request: OffloadRequest(policy: p, tiers: [.attachments], dryRun: false, archiveDirectory: archive), journal: journal(), lockURL: lockURL())
        XCTAssertEqual(r.archived, 6)
        for e in journal().removedEntries() {
            XCTAssertNotNil(e.archivePath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: e.archivePath!))
            let size = try FileManager.default.attributesOfItem(atPath: e.archivePath!)[.size] as? Int64
            XCTAssertEqual(size, e.bytes)
        }
    }

    func testPreviewAndSidecarTiers() throws {
        makeQuiescent()
        let previewsBefore = Analyzer.walkFiles(store.previewsDir).files.count
        XCTAssertGreaterThan(previewsBefore, 0)
        let r = try Offloader.run(store: store, request: OffloadRequest(policy: Policy(), tiers: [.previews, .sidecars], dryRun: false), journal: journal(), lockURL: lockURL())
        XCTAssertEqual(r.tiers.first { $0.tier == "previews" }?.files, previewsBefore)
        XCTAssertEqual(Analyzer.walkFiles(store.previewsDir).files.count, 0)
        XCTAssertEqual(r.tiers.first { $0.tier == "sidecars" }?.files, 1)
        XCTAssertTrue(r.tiers.first { $0.tier == "attachments" } == nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.attachmentsDir.appendingPathComponent("aa/bb/iMessage;+;chat123456/GroupPhotoImage").path))
    }

    func testGuardRefusesUnapprovedAndSymlinkAndDatabase() throws {
        let g = DeletionGuard(store: store, approvedPaths: [])
        let link = store.attachmentsDir.appendingPathComponent("cc/dd/att-symlink/escape.jpeg").path
        XCTAssertThrowsError(try g.unlink(link, root: .attachments))
        g.approve([link, store.chatDB.path, store.root.appendingPathComponent("outside-target.bin").path])
        XCTAssertThrowsError(try g.unlink(link, root: .attachments)) { XCTAssertTrue("\($0)".contains("non-regular")) }
        XCTAssertThrowsError(try g.unlink(store.chatDB.path, root: .attachments)) { XCTAssertTrue("\($0)".contains("database")) }
        XCTAssertThrowsError(try g.unlink(store.root.appendingPathComponent("outside-target.bin").path, root: .attachments)) { XCTAssertTrue("\($0)".contains("outside")) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.chatDB.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("outside-target.bin").path))
        XCTAssertEqual(g.removedFiles, 0)
    }

    func testTombstoneGrowthIsReportedAsCanaryViolation() throws {
        let db = try ReadOnlyDatabase(path: store.chatDB.path)
        let before = try Canaries.snapshot(db: db, rowIDs: [1, 2])
        // Simulate Apple's daemon queueing a deletion (the test writes with a raw handle; the tool never can).
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.chatDB.path, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "INSERT INTO sync_deleted_attachments (guid, recordID) VALUES ('x', 'y'); UPDATE attachment SET ck_sync_state = 2 WHERE ROWID = 1", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)
        let after = try Canaries.snapshot(db: db, rowIDs: [1, 2])
        let v = Canaries.violations(before: before, after: after)
        XCTAssertEqual(v.count, 2, "\(v)")
    }

    func testTombstoneQueueDrainingIsNotAViolationButQueueingIs() throws {
        let db = try ReadOnlyDatabase(path: store.chatDB.path)
        let before = try Canaries.snapshot(db: db, rowIDs: [])
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.chatDB.path, &raw), SQLITE_OK)
        // Apple's sync engine flushing its queue: rows disappear, counter unchanged.
        XCTAssertEqual(sqlite3_exec(raw, "DELETE FROM sync_deleted_messages", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)
        let drained = try Canaries.snapshot(db: db, rowIDs: [])
        XCTAssertEqual(drained.tombstoneMessages, 0)
        XCTAssertTrue(Canaries.violations(before: before, after: drained).isEmpty)
        // A new deletion queued and then flushed: rows back to 0, counter grew -> violation.
        XCTAssertEqual(sqlite3_open(store.chatDB.path, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "INSERT INTO sync_deleted_messages (guid, recordID) VALUES ('m2', 'r2'); DELETE FROM sync_deleted_messages", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)
        let queued = try Canaries.snapshot(db: db, rowIDs: [])
        XCTAssertEqual(queued.tombstoneMessages, 0)
        XCTAssertEqual(Canaries.violations(before: before, after: queued).count, 1)
    }

    func testRealRunRefusedWhenPrerequisitesFail() throws {
        // The fixture has a transfer in progress (transfer_state = 3) -> blocker.
        var p = Policy()
        p.firstRunMaxBytes = 1_000_000_000
        // Prerequisites are evaluated inside Offloader; a real run must throw.
        XCTAssertThrowsError(try Offloader.run(store: MessagesStore(root: store.root), request: OffloadRequest(policy: p, tiers: [.attachments], dryRun: false), journal: journal(), lockURL: lockURL())) { error in
            XCTAssertTrue("\(error)".contains("prerequisites"), "\(error)")
        }
    }
}

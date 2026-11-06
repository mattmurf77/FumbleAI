import Foundation
import XCTest
import GRDB
import HomeCore
@testable import HomeStore

final class RecordIntegrityTests: XCTestCase {
    func testUpgradePreservesHistoricalWorkAndLinkedReceiptThenAcceptsUndatedWork() throws {
        let q = try DatabaseQueue(configuration: AppDatabase.configuration())
        try Migrations.migrator.migrate(q, upTo: Migrations.v2OutdoorThings)
        try q.write { db in
            let stamp = "2026-09-29 12:00:00.000"
            try db.execute(sql: "INSERT INTO property(id,created_at,updated_at) VALUES('home',?,?)", arguments: [stamp,stamp])
            try db.execute(sql: """
                INSERT INTO project(id,property_id,scope,title,status,completed_on,actual_cost_cents,created_at,updated_at)
                VALUES ('proj','home','property','Roof','done','2018-07-14',877551,?,?)
                """, arguments: [stamp,stamp])
            try db.execute(sql: """
                INSERT INTO attachment(id,property_id,owner_type,owner_id,kind,file_ext,uti,byte_size,sha256,created_at,updated_at)
                VALUES ('receipt','home','cost_line_item','line','receipt','pdf','com.adobe.pdf',22,'sha',?,?)
                """, arguments: [stamp,stamp])
            try db.execute(sql: """
                INSERT INTO cost_line_item(id,property_id,project_id,label,amount_cents,receipt_attachment_id,created_at,updated_at)
                VALUES ('line','home','proj','Shingles',40000,'receipt',?,?)
                """, arguments: [stamp,stamp])
        }
        try Migrations.migrator.migrate(q)
        try q.write { db in
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT work_action FROM project WHERE id='proj'"))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT completed_on FROM project WHERE id='proj'"), "2018-07-14")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT actual_cost_cents FROM project WHERE id='proj'"), 877551)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT project_id FROM cost_line_item WHERE id='line'"), "proj")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT receipt_attachment_id FROM cost_line_item WHERE id='line'"), "receipt")
            try db.execute(sql: "UPDATE project SET completed_on=NULL WHERE id='proj'")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT status FROM project WHERE id='proj'"), "done")
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    func testWholePropertyPastWorkAndReceiptsPersistOnRelaunch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HomeStore.live(directory: dir, clock: clock)
        let home = Property(name: "House")
        try await store.plan.saveProperty(home)
        let work = try await store.projects.create(.init(propertyId: home.id, scope: .property, title: "Roof", status: .done, workAction: .repaired))
        XCTAssertNil(work.completedOn)
        XCTAssertNil(work.actualCost)
        let source = dir.appendingPathComponent("receipt.pdf")
        let evidence = Data("receipt fixture".utf8)
        try evidence.write(to: source)
        let draft = AttachmentDraft(fileURL: source, kind: .receipt, uti: "com.adobe.pdf")
        let line = CostLineItem(propertyId: home.id, projectId: work.id, label: "Flashing", amount: Money(cents: 7941))
        try await store.projects.upsertLineItem(line, receipt: draft)
        let reopened = try HomeStore.live(directory: dir, clock: clock)
        let found = try await reopened.projects.project(work.id)
        XCTAssertEqual(found?.status, .done)
        XCTAssertEqual(found?.workAction, .repaired)
        let table = try await reopened.database.read { db in try CSVExporter.tables(db, property: home.id)["projects.csv"] }
        let (headers, rows) = try XCTUnwrap(table)
        let actionColumn = try XCTUnwrap(headers.firstIndex(of: "work_action"))
        XCTAssertEqual(rows.first?[actionColumn], "repaired")
        XCTAssertNil(found?.completedOn)
        let lines = try await reopened.projects.lineItems(project: work.id)
        let attachments = try await reopened.attachments.attachments(ownerType: .costLineItem, ownerId: line.id)
        XCTAssertEqual(lines.first?.receiptAttachmentId, attachments.first?.id)
        XCTAssertEqual(lines.first?.amount.cents, 7941)
        let attachment = try XCTUnwrap(attachments.first)
        let file = await reopened.attachments.fileURL(for: attachment)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(file)), evidence)
        try await reopened.projects.markDone(work.id, actual: Money(cents: 0), completedOn: today, hours: 0, receipt: nil)
        let zeroCost = try await reopened.projects.project(work.id)
        XCTAssertEqual(zeroCost?.actualCost?.cents, 0)
        XCTAssertEqual(zeroCost?.workAction, .repaired, "An older completion caller keeps the owner's answer")
        try await reopened.projects.markDone(work.id, actual: nil, completedOn: today, hours: nil, receipt: nil,
                                             workAction: .set(.replaced))
        let classified = try await reopened.projects.project(work.id)
        XCTAssertEqual(classified?.workAction, .replaced)
        try await reopened.projects.markDone(work.id, actual: nil, completedOn: today, hours: nil, receipt: nil,
                                             workAction: .set(nil))
        let cleared = try await reopened.projects.project(work.id)
        XCTAssertNil(cleared?.workAction)
        XCTAssertNil(cleared?.actualCost)
        XCTAssertNil(cleared?.actualHours)
        let previousFiles = try FileManager.default.contentsOfDirectory(atPath: reopened.files.directory.path)
        var bad = line; bad.id = UUID(); bad.projectId = UUID()
        do { try await reopened.projects.upsertLineItem(bad, receipt: draft); XCTFail("Must reject missing project") }
        catch RepositoryError.notFound {}
        let unlinked = try await reopened.attachments.attachments(ownerType: .costLineItem, ownerId: bad.id)
        XCTAssertTrue(unlinked.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: reopened.files.directory.path).sorted(), previousFiles.sorted())
        do { try reopened.files.adopt(downloaded: dir.appendingPathComponent("missing.pdf"), id: attachment.id, ext: "pdf"); XCTFail() }
        catch { XCTAssertEqual(try Data(contentsOf: XCTUnwrap(file)), evidence) }
    }

    func testUndoRemovesCompletionAndRestoresOccurrenceWithoutOverwritingLaterActions() async throws {
        let store = try HomeStore.inMemory(clock: clock)
        let home = Property(name: "House")
        try await store.plan.saveProperty(home)
        let task = try await store.chores.create(.init(propertyId: home.id, scope: .property, title: "Filter", startOn: today))
        let first = try await store.chores.complete(task.id, by: nil, at: clock.now)
        do { _ = try await store.chores.complete(task.id, by: nil, at: clock.now); XCTFail("Double completion") }
        catch RepositoryError.invalid {}
        try await store.chores.undoCompletion(first.id)
        let history = try await store.chores.completions(chore: task.id)
        let restored = try await store.chores.chore(task.id)
        XCTAssertTrue(history.isEmpty)
        XCTAssertEqual(restored?.nextDueOn, task.nextDueOn)
        XCTAssertNil(restored?.closedAt)
        let skip = try await store.chores.skip(task.id, at: clock.now)
        let next = today.adding(days: 5)
        try await store.chores.reschedule(task.id, to: next)
        do { try await store.chores.undoCompletion(skip.id); XCTFail("Must preserve later reschedule") }
        catch RepositoryError.invalid {}
        let changed = try await store.chores.chore(task.id)
        XCTAssertEqual(changed?.nextDueOn, next)
    }
}

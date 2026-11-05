import Foundation
import GRDB
import HomeCore
import XCTest
@testable import HomeStore

final class DocumentLibraryTests: XCTestCase {
    func testOriginalMetadataScopeDuplicatesSyncAndRecovery() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = Property(), other = Property()
        let file = dir.appendingPathComponent("Proposal A.pdf"), body = Data("%PDF-1.4 synthetic original".utf8)
        let docID: UUID
        do {
            let store = try HomeStore.live(directory: dir)
            try await store.plan.saveProperty(home); try await store.plan.saveProperty(other)
            let project = try await store.projects.create(.init(propertyId: home.id, scope: .property, title: "Roof upgrade", status: .done))
            try body.write(to: file)
            let input = AttachmentDraft(fileURL: file, kind: .document, uti: "com.adobe.pdf")
            let meta = HomeDocumentDetails(title: "Roof proposal", originalFilename: file.lastPathComponent, category: .estimate, documentDate: LocalDate(2026, 5, 1), projectId: project.id, quoteAmount: Money(cents: 124050, currency: "CAD"), confirmedFields: ["issuer": "Maple Co.", "referenceNumber": "E789"])
            let doc = try await store.attachments.fileDocument(input, propertyId: home.id, details: meta); docID = doc.id
            XCTAssertEqual(doc.attachment.ownerType, .property); XCTAssertTrue(doc.matches("maple E789"))
            do { _ = try await store.attachments.fileDocument(input, propertyId: home.id, details: meta); XCTFail("Created duplicate") } catch is HomeDocumentError {}
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.files.directory.path).count, 1)
            var all = store.attachments.observeDocuments(propertyId: other.id).makeAsyncIterator()
            let foreign = await all.next(); XCTAssertEqual(foreign?.count, 0)
            let enqueued = try await store.sync.perform { try $0.enqueueAll(property: home.id) }
            XCTAssertFalse(enqueued.contains(RecordRef(.attachment, docID)))
            for include in [false, true] {
                let output = try await store.export.exportCSV(property: home.id, options: ExportOptions(includeAttachments: include))
                let folder = output.pathExtension == "zip" ? output.deletingPathExtension() : output
                let manifest = folder.appendingPathComponent("documents.csv")
                XCTAssertEqual(FileManager.default.fileExists(atPath: manifest.path), include)
                if include {
                    let csv = try String(contentsOf: manifest, encoding: .utf8)
                    XCTAssertTrue(csv.contains("1240.50,CAD")); XCTAssertTrue(csv.contains("Proposal A.pdf")); XCTAssertTrue(csv.contains("E789"))
                    let copies = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("attachments"), includingPropertiesForKeys: nil)
                    XCTAssertEqual(copies.count, 1); XCTAssertEqual(try Data(contentsOf: XCTUnwrap(copies.first)), body)
                }
            }
            let pending = try await store.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sync_outbox WHERE record_name = ?", arguments: [docID.uuidString.lowercased()]) }
            XCTAssertEqual(pending, 0)
            var edited = meta; edited.confirmedFields = [:]; edited.projectId = nil
            try await store.attachments.updateDocument(doc, details: edited)
            do { try await store.attachments.updateDocument(doc, details: meta); XCTFail("Stale overwrite") } catch is HomeDocumentError {}
            try FileManager.default.removeItem(at: file)
        }
        let reopened = try HomeStore.live(directory: dir)
        var live = reopened.attachments.observeDocuments(propertyId: home.id).makeAsyncIterator()
        let current = await live.next(); let saved = try XCTUnwrap(current?.first)
        XCTAssertEqual(saved.id, docID); XCTAssertNil(saved.linkedProjectId); XCTAssertFalse(saved.matches("E789")); XCTAssertEqual(saved.details.originalFilename, "Proposal A.pdf")
        let localURL = await reopened.attachments.fileURL(for: saved.attachment); let original = try XCTUnwrap(localURL)
        XCTAssertEqual(try Data(contentsOf: original), body)
        try await reopened.attachments.delete(docID)
        let removed = try await reopened.recentlyDeleted.deleted(property: home.id); XCTAssertTrue(removed.contains { $0.ref == .init(.attachment, docID) })
        try await reopened.recentlyDeleted.restore(.init(.attachment, docID)); XCTAssertEqual(try Data(contentsOf: original), body)
        try await reopened.attachments.delete(docID); try await reopened.recentlyDeleted.purge(.init(.attachment, docID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        let pending = try await reopened.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sync_outbox WHERE record_name = ?", arguments: [docID.uuidString.lowercased()]) }
        XCTAssertEqual(pending, 0)
    }

    func testBuild20ReceiptIsDiscoveredAndKeepsLineLinkAcrossMigration() throws {
        let q = try DatabaseQueue(configuration: AppDatabase.configuration()), pid = UUID(), project = UUID(), line = UUID(), file = UUID()
        try Migrations.migrator.migrate(q, upTo: Migrations.v2OutdoorThings)
        try q.write { db in
            let now = "2026-09-03 12:00:00.000"
            try db.execute(sql: "INSERT INTO property(id,created_at,updated_at) VALUES(?,?,?)", arguments: [pid.db, now, now])
            try db.execute(sql: "INSERT INTO project(id,property_id,scope,title,status,created_at,updated_at) VALUES(?,?,'property','Roof','idea',?,?)", arguments: [project.db, pid.db, now, now])
            try db.execute(sql: "INSERT INTO attachment(id,property_id,owner_type,owner_id,kind,file_ext,uti,byte_size,sha256,created_at,updated_at) VALUES(?,?,'cost_line_item',?,'receipt','pdf','com.adobe.pdf',22,'abc',?,?)", arguments: [file.db, pid.db, line.db, now, now])
            try db.execute(sql: "INSERT INTO cost_line_item(id,property_id,project_id,label,amount_cents,kind,receipt_attachment_id,created_at,updated_at) VALUES(?,?,?,'Roof',200,'labor',?,?,?)", arguments: [line.db,pid.db,project.db,file.db,now,now])
        }
        try Migrations.migrator.migrate(q)
        try q.read { db in
            let doc = try XCTUnwrap(AttachmentStore.documents(db, propertyId: pid).first)
            XCTAssertEqual(doc.id, file); XCTAssertNil(doc.details.originalFilename); XCTAssertEqual(doc.details.category, .receipt); XCTAssertEqual(doc.linkedProjectId, project)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT receipt_attachment_id FROM cost_line_item"), file.db)
            XCTAssertEqual(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count, 0)
        }
    }
}

import Foundation
import Testing
import HomeCore
import HomeStore
@testable import HomeSync

struct SyncBoundaryTests {
    @Test func validHouseholdRecordsStillRestoreAndAcceptPartialUpdates() async throws {
        let source = try HomeStore.inMemory(), restored = try HomeStore.inMemory()
        let home = Property(name: "Home")
        try await source.plan.saveProperty(home)
        let task = try await source.chores.create(.init(propertyId: home.id, scope: .property, title: "Paint", startOn: .init(2026, 11, 5)))
        let project = try await source.chores.turnIntoProject(task.id)
        let sender = try SyncProcessor(store: source.sync), receiver = try SyncProcessor(store: restored.sync)
        var records: [SyncRecord] = []
        for ref in [RecordRef(.project, project.id), .init(.chore, task.id), .init(.property, home.id)] {
            records.append(try #require(try await sender.buildRecord(ref)))
        }
        let outcome = try await receiver.applyFetched(modifications: records, deletions: [])
        #expect(outcome.applied == 3 && outcome.parked == 0)
        #expect(try await restored.projects.project(project.id)?.spawnedFromChoreId == task.id)
        let update = SyncRecord(recordType: RecordType.chore.rawValue, recordName: task.id.uuidString.lowercased(),
                                zoneName: Property.zoneName(for: home.id), fields: ["title": .string("Paint bedroom")])
        let changed = try await receiver.applyFetched(modifications: [update], deletions: [])
        #expect(changed.applied == 1 && changed.parked == 0)
        #expect(try await restored.chores.chore(task.id)?.title == "Paint bedroom")
    }

    @Test func outOfRangeOrFractionalNumbersDoNotTrapOrTruncate() {
        #expect(RecordMapper.coerce(.double(42), to: .int) == .int(42))
        #expect(RecordMapper.coerce(.double(42.5), to: .int) == .double(42.5))
        #expect(RecordMapper.coerce(.double(.greatestFiniteMagnitude), to: .int) == .double(.greatestFiniteMagnitude))
        #expect(RecordMapper.coerce(.double(.infinity), to: .int) == .double(.infinity))
    }

    @Test func wrongHouseholdZoneIsParkedAndCannotReplaceConflictMetadata() async throws {
        let store = try HomeStore.inMemory()
        let home = Property(name: "Home")
        try await store.plan.saveProperty(home)
        let task = try await store.chores.create(.init(propertyId: home.id, scope: .property, title: "Paint", startOn: .init(2026, 11, 5)))
        let processor = try SyncProcessor(store: store.sync)
        let ref = RecordRef(.chore, task.id)
        let sent = try #require(try await processor.buildRecord(ref))
        var invalid = sent
        invalid.zoneName = Property.zoneName(for: UUID())
        invalid.fields["title"] = .string("Wrong home")
        invalid.systemFields = Data("wrong tag".utf8)
        let outcome = try await processor.applyFetched(modifications: [invalid], deletions: [])
        #expect(outcome.parked == 1 && outcome.applied == 0)
        #expect(try await store.chores.chore(task.id)?.title == "Paint")
        let follow = try await processor.handleFailedSave(sent, error: .serverRecordChanged(server: invalid))
        if case .failed = follow {} else { Issue.record("Invalid conflict must not be sent again with its tag") }
        #expect(try await store.sync.perform { try $0.systemFields(ref) } == nil)
        #expect(try await store.sync.outboxEntry(ref) != nil)
    }

    @Test func deviceOnlyDocumentCannotBeRequestedOverwrittenOrDeletedBySync() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HomeStore.live(directory: directory)
        let home = Property(name: "Home")
        try await store.plan.saveProperty(home)
        let original = directory.appendingPathComponent("permit.pdf")
        let bytes = Data("Owner's original permit".utf8)
        try bytes.write(to: original)
        let document = try await store.attachments.fileDocument(.init(fileURL: original, kind: .document, uti: "com.adobe.pdf"),
            propertyId: home.id, details: .init(title: "Permit", originalFilename: "permit.pdf", category: .permit))
        let processor = try SyncProcessor(store: store.sync)
        let ref = RecordRef(.attachment, document.id)
        #expect(try await processor.buildRecord(ref) == nil)
        let mapper = try #require(processor.mappers[.attachment])
        let row = try #require(try await store.sync.perform { try $0.row(ref) })
        var remote = mapper.record(id: document.id, row: row, zoneName: Property.zoneName(for: home.id), systemFields: nil, assetURL: nil)
        remote.fields["caption"] = .string("Remote overwrite")
        let outcome = try await processor.applyFetched(modifications: [remote], deletions: [ref])
        #expect(outcome.parked == 1 && outcome.applied == 0)
        let after = try #require(try await store.sync.perform { try $0.row(ref) })
        #expect(after == row)
        let saved = try #require(await store.attachments.fileURL(for: document.attachment))
        #expect(try Data(contentsOf: saved) == bytes)
    }
}

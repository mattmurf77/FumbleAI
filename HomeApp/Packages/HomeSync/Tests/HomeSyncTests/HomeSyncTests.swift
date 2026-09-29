import Foundation
import XCTest
import HomeCore
import HomeCoreTesting
import PlanKit
@testable import HomeStore
@testable import HomeSync

let today = LocalDate(2026, 9, 29)
let clock = FixedClock(LocalDate(2026, 9, 29))

/// One simulated device: its own database + coordinator over a shared fake cloud.
struct Device {
    let store: HomeStore
    let engine: FakeEngine
    let sync: SyncCoordinator

    static func make(_ cloud: FakeCloud) throws -> Device {
        let store = try HomeStore.inMemory(clock: clock)
        let engine = FakeEngine(cloud: cloud)
        return Device(store: store, engine: engine, sync: try SyncCoordinator(store: store, driver: engine))
    }

    func syncNow() async throws {
        try await sync.syncNow()
        // Let local-change listener tasks enqueue before the next round.
        try await Task.sleep(nanoseconds: 50_000_000)
        try await sync.syncNow()
    }
}

/// Seeds `SampleHome` with origin `.sync`, then marks every row pending (as after iCloud sign-in).
func seedSample(_ d: Device) async throws {
    let s = SampleHome.snapshot(today: today, now: clock.now)
    try await d.store.database.write(origin: .sync) { tx in
        for x in s.properties.values { try tx.save(x) }
        for x in s.people.values { try tx.save(x) }
        for x in s.levels.values { try tx.save(x) }
        for x in s.spaces.values { try tx.save(x) }
        for x in s.openings.values { try tx.save(x) }
        for x in s.spots.values.sorted(by: { ($0.parentSpotId == nil ? 0 : 1) < ($1.parentSpotId == nil ? 0 : 1) }) { try tx.save(x) }
        for x in s.measurements.values { try tx.save(x) }
        for x in s.things.values { try tx.save(x) }
        for x in s.chores.values { try tx.save(x) }
        for x in s.projects.values { try tx.save(x) }
        for x in s.lineItems.values { try tx.save(x) }
        for x in s.inventory.values { try tx.save(x) }
    }
    try await d.store.sync.perform { st in _ = try st.enqueueAll() }
}

final class MapperAndMergeTests: XCTestCase {
    func testMapperRoundTripsEveryTableAndUsesCamelCase() async throws {
        let d = try Device.make(FakeCloud())
        try await seedSample(d)
        let mappers = d.sync.processor.mappers
        let refs = try await d.store.sync.outbox().map(\.ref)
        XCTAssertEqual(refs.count, 54)
        for ref in refs {
            let row = try await d.store.sync.perform { try $0.row(ref) }!
            let m = mappers[ref.type]!
            let rec = m.record(id: ref.id, row: row, zoneName: "property-x", systemFields: nil, assetURL: nil)
            XCTAssertEqual(rec.recordType, ref.type.rawValue)
            XCTAssertEqual(rec.fields["schemaVersion"], .int(SyncSchema.version))
            XCTAssertNil(rec.fields["area_sq_in"]); XCTAssertNil(rec.fields["areaSqIn"], "derived caches are not synced")
            XCTAssertEqual(m.row(from: rec), row, "\(ref.type)")
        }
        let chore = try await d.store.sync.perform { try $0.row(RecordRef(.chore, SampleHome.filterId)) }!
        let rec = mappers[.chore]!.record(id: SampleHome.filterId, row: chore, zoneName: "z", systemFields: nil, assetURL: nil)
        XCTAssertNotNil(rec.fields["nextDueOn"]); XCTAssertNotNil(rec.fields["repeatRuleJson"]); XCTAssertNotNil(rec.fields["propertyId"])
        let kitchenRow = try await d.store.sync.perform { try $0.row(RecordRef(.space, SampleHome.kitchenId)) }!
        let kitchenRec = mappers[.space]!.record(id: SampleHome.kitchenId, row: kitchenRow, zoneName: "z", systemFields: nil, assetURL: nil)
        XCTAssertEqual(Set(mappers[.space]!.parentRefs(of: kitchenRec)), [RecordRef(.property, SampleHome.propertyId), RecordRef(.level, SampleHome.firstFloorId)])
    }

    func testMergePolicyRules() {
        let t0 = Date(timeIntervalSince1970: 1_000), t1 = Date(timeIntervalSince1970: 2_000)
        // Column overlay: local rename + server reshape both survive.
        var server: SyncRow = ["name": .string("Kitchen"), "polygon_json": .string("[[0,0],[2,0],[2,2]]"), "updated_at": .date(t1), "deleted_at": .null]
        var local: SyncRow = ["name": .string("Cook room"), "polygon_json": .string("[[0,0],[1,0],[1,1]]"), "updated_at": .date(t0), "deleted_at": .null]
        var m = MergePolicy.merge(.space, server: server, local: local, changed: ["name"], today: today)
        XCTAssertEqual(m["name"], .string("Cook room")); XCTAssertEqual(m["polygon_json"], server["polygon_json"]); XCTAssertEqual(m["updated_at"], .date(t1))
        // Delete wins unless deleted_at was changed locally (restore).
        server["deleted_at"] = .date(t1)
        m = MergePolicy.merge(.space, server: server, local: local, changed: ["name"], today: today)
        XCTAssertEqual(m["deleted_at"], .date(t1))
        m = MergePolicy.merge(.space, server: server, local: local, changed: ["deleted_at"], today: today)
        XCTAssertEqual(m["deleted_at"], .null)
        // Project status + completed_on paired; done without date gets one.
        server = ["status": .string("done"), "completed_on": .string("2026-09-01")]
        local = ["status": .string("in_progress"), "completed_on": .null]
        m = MergePolicy.merge(.project, server: server, local: local, changed: ["status"], today: today)
        XCTAssertEqual(m["status"], .string("in_progress")); XCTAssertEqual(m["completed_on"], .null)
        local = ["status": .string("done"), "completed_on": .null]
        server = ["status": .string("planned"), "completed_on": .null]
        m = MergePolicy.merge(.project, server: server, local: local, changed: ["status"], today: today)
        XCTAssertEqual(m["completed_on"], .string("2026-09-29"))
        // Thing attributes: key-level overlay.
        server = ["attributes_json": .string(#"{"filterSize":"16x25x1","merv":8}"#)]
        local = ["attributes_json": .string(#"{"filterSize":"20x25x1","merv":11}"#)]
        m = MergePolicy.merge(.thing, server: server, local: local, changed: ["attributes_json", "attributes_json.merv"], today: today)
        XCTAssertEqual(m["attributes_json"], .string(#"{"filterSize":"16x25x1","merv":11}"#))
        // Inventory location group moves together.
        server = ["scope": .string("level"), "space_id": .null, "level_id": .string("L2"), "storage_spot_id": .null, "quantity": .double(5)]
        local = ["scope": .string("space"), "space_id": .string("S1"), "level_id": .string("L1"), "storage_spot_id": .string("P1"), "quantity": .double(1)]
        m = MergePolicy.merge(.inventoryItem, server: server, local: local, changed: ["storage_spot_id"], today: today)
        XCTAssertEqual(m["scope"], .string("space")); XCTAssertEqual(m["level_id"], .string("L1")); XCTAssertEqual(m["quantity"], .double(5))
        // Calendar link fields move as a group.
        server = ["owner_device_id": .string("A"), "calendar_title": .string("Home"), "event_external_id": .string("x")]
        local = ["owner_device_id": .string("B"), "calendar_title": .string("Family"), "event_external_id": .string("y")]
        m = MergePolicy.merge(.choreCalendarLink, server: server, local: local, changed: ["owner_device_id"], today: today)
        XCTAssertEqual(m["calendar_title"], .string("Family")); XCTAssertEqual(m["event_external_id"], .string("y"))
    }

    func testUnknownEnumValuesAreSkippedOnWrite() {
        let schema = SyncTableSchema(recordType: .space, columns: [
            SyncColumn(name: "space_type", kind: .text, notNull: true, hasDefault: true, references: nil, enumValues: ["room"])])
        let rec = RecordMapper(schema: schema).record(id: UUID(), row: ["space_type": .string("sunroom")], zoneName: "z", systemFields: nil, assetURL: nil)
        XCTAssertNil(rec.fields["spaceType"], "never overwrite a newer build's value")
    }
}

final class TwoDeviceSyncTests: XCTestCase {
    func testFullHomeReachesSecondDeviceIncludingOrphanOrdering() async throws {
        let cloud = FakeCloud()
        let a = try Device.make(cloud), b = try Device.make(cloud)
        try await seedSample(a)
        try await a.sync.start()
        try await a.syncNow()
        let pendingA = try await a.store.sync.outboxCount()
        XCTAssertEqual(pendingA, 0, "everything sent")
        XCTAssertEqual(cloud.recordCount, 54)
        let restore = await b.sync.restoreCheck(timeout: 2)
        XCTAssertEqual(restore, .existingHomeFound(propertyId: SampleHome.propertyId))
        b.engine.childrenFirst = true
        try await b.sync.start()
        try await b.sync.syncNow()
        let orphans = try await b.store.sync.orphanCount()
        XCTAssertEqual(orphans, 0, "AC-SYN-8: parked children applied once parents arrived")
        let pid = SampleHome.propertyId
        let choresA = try await a.store.chores.chores(ChoreQuery(propertyId: pid))
        let choresB = try await b.store.chores.chores(ChoreQuery(propertyId: pid))
        XCTAssertEqual(choresA, choresB)
        let geoA = try await a.store.plan.geometry(level: SampleHome.firstFloorId)
        let geoB = try await b.store.plan.geometry(level: SampleHome.firstFloorId)
        XCTAssertEqual(geoA.spaces, geoB.spaces)
        let invA = try await a.store.inventory.locations(of: [SampleHome.id(120)])
        let invB = try await b.store.inventory.locations(of: [SampleHome.id(120)])
        XCTAssertEqual(invA, invB)
        // Search works on B (FTS indexed during apply).
        let hits = try await b.store.search.search("winter coat", property: pid)
        XCTAssertEqual(hits.first?.entityId, SampleHome.id(120))
        let pendingB = try await b.store.sync.outboxCount()
        XCTAssertEqual(pendingB, 0, "applies never re-enqueue")
    }

    func testFieldDisjointEditsBothSurvive() async throws {
        let cloud = FakeCloud()
        let a = try Device.make(cloud), b = try Device.make(cloud)
        try await seedSample(a)
        try await a.sync.start(); try await a.syncNow()
        try await b.sync.start(); try await b.syncNow()
        // Offline: A renames the kitchen, B enlarges it into the (free) space below? Keep it simple: B changes color.
        try await a.store.plan.renameSpace(SampleHome.kitchenId, to: "Cook Room")
        var k = try await b.store.plan.space(SampleHome.kitchenId)!
        k.colorHex = "#FFEEAA"
        try await b.store.plan.updateSpaces([.update(k)])
        try await a.syncNow()
        // B sends first on a stale change tag → serverRecordChanged → merge → resend.
        try await Task.sleep(nanoseconds: 50_000_000)
        try await b.engine.sendChanges()
        try await b.syncNow()
        try await a.syncNow()
        for d in [a, b] {
            let s = try await d.store.plan.space(SampleHome.kitchenId)
            XCTAssertEqual(s?.name, "Cook Room"); XCTAssertEqual(s?.colorHex, "#FFEEAA")
        }
        let server = cloud.record(Property.zoneName(for: SampleHome.propertyId), SampleHome.kitchenId.uuidString.lowercased())
        XCTAssertEqual(server?.fields["name"], .string("Cook Room")); XCTAssertEqual(server?.fields["colorHex"], .string("#FFEEAA"))
    }

    func testDeleteWinsOverConcurrentEdit() async throws {
        let cloud = FakeCloud()
        let a = try Device.make(cloud), b = try Device.make(cloud)
        try await seedSample(a)
        try await a.sync.start(); try await a.syncNow()
        try await b.sync.start(); try await b.syncNow()
        try await a.store.projects.delete(SampleHome.deckId)
        var p = try await b.store.projects.project(SampleHome.deckId)!
        p.notes = "Composite boards"
        try await b.store.projects.update(p)
        try await a.syncNow()
        try await Task.sleep(nanoseconds: 50_000_000)
        try await b.engine.sendChanges()
        try await b.syncNow()
        try await a.syncNow()
        for d in [a, b] {
            let gone = try await d.store.projects.project(SampleHome.deckId)
            XCTAssertNil(gone, "AC-SYN-3: delete wins")
            let bin = try await d.store.recentlyDeleted.deleted(property: SampleHome.propertyId)
            XCTAssertTrue(bin.contains { $0.ref == RecordRef(.project, SampleHome.deckId) })
        }
    }

    func testConcurrentCompletionsKeepBothAndAgreeOnNextDue() async throws {
        let cloud = FakeCloud()
        let a = try Device.make(cloud), b = try Device.make(cloud)
        try await seedSample(a)
        try await a.sync.start(); try await a.syncNow()
        try await b.sync.start(); try await b.syncNow()
        _ = try await a.store.chores.complete(SampleHome.dishesId, by: SampleHome.mattId, at: clock.now)
        _ = try await b.store.chores.complete(SampleHome.dishesId, by: SampleHome.alexId, at: clock.now.addingTimeInterval(60))
        try await a.syncNow(); try await b.syncNow(); try await a.syncNow()
        let ca = try await a.store.chores.completions(chore: SampleHome.dishesId)
        let cb = try await b.store.chores.completions(chore: SampleHome.dishesId)
        XCTAssertEqual(ca.count, 2); XCTAssertEqual(Set(ca.map(\.id)), Set(cb.map(\.id)))
        let na = try await a.store.chores.chore(SampleHome.dishesId), nb = try await b.store.chores.chore(SampleHome.dishesId)
        XCTAssertEqual(na?.nextDueOn, nb?.nextDueOn)
        XCTAssertEqual(na?.nextDueOn, today.adding(days: 1))
    }

    func testUnknownEnumFromNewerBuildIsParkedNotDropped() async throws {
        let cloud = FakeCloud()
        let a = try Device.make(cloud), b = try Device.make(cloud)
        try await seedSample(a)
        try await a.sync.start(); try await a.syncNow()
        var sun = cloud.record(Property.zoneName(for: SampleHome.propertyId), SampleHome.kitchenId.uuidString.lowercased())!
        sun.recordName = UUID().uuidString.lowercased()
        sun.fields["spaceType"] = .string("sunroom")
        sun.fields["name"] = .string("Sunroom")
        sun.fields["schemaVersion"] = .int(2)
        sun.systemFields = nil
        cloud.inject(sun)
        try await b.sync.start(); try await b.syncNow()
        let parked = try await b.store.sync.perform { try $0.orphans() }
        XCTAssertEqual(parked.count, 1)
        XCTAssertEqual(parked.first?.missingParent, "schema:space_type=sunroom")
        let spaces = try await b.store.plan.spaces(property: SampleHome.propertyId)
        XCTAssertFalse(spaces.contains { $0.name == "Sunroom" })
        let diag = await b.sync.diagnostics()
        XCTAssertEqual(diag.parkedOrphans, 1)
    }

    func testZoneRecreatedWhenMissingAndStatusReportsPending() async throws {
        let cloud = FakeCloud()
        let a = try Device.make(cloud)
        try await seedSample(a)
        try await a.sync.start(); try await a.syncNow()
        cloud.deleteZone(Property.zoneName(for: SampleHome.propertyId))
        try await a.store.chores.reschedule(SampleHome.trashId, to: today.adding(days: 2))
        try await Task.sleep(nanoseconds: 50_000_000)
        let status = try await firstValue(a.sync.observeStatus())
        if case .pending(let n) = status { XCTAssertEqual(n, 1) } else { XCTFail("\(status)") }
        try await a.syncNow()
        XCTAssertTrue(cloud.zones.contains(Property.zoneName(for: SampleHome.propertyId)))
        XCTAssertEqual(cloud.recordCount, 54, "zoneNotFound → zone re-created and every row re-uploaded")
        let pending = try await a.store.sync.outboxCount()
        XCTAssertEqual(pending, 0)
    }

    func testLiveCoordinatorWithoutCloudKitIsOff() async throws {
        #if !canImport(CloudKit)
        let store = try HomeStore.inMemory(clock: clock)
        let c = try SyncCoordinator.live(store: store, containerIdentifier: AppConfig().cloudKitContainerIdentifier)
        try await c.start()
        let s = try await firstValue(c.observeStatus())
        XCTAssertEqual(s, .iCloudOff)
        let r = await c.restoreCheck(timeout: 1)
        XCTAssertEqual(r, .unavailable)
        #endif
    }
}

func firstValue<T: Sendable>(_ s: AsyncStream<T>) async throws -> T {
    for await v in s { return v }
    throw CancellationError()
}

import Foundation
import XCTest
import HomeCore
import HomeCoreTesting
import PlanKit
@testable import HomeStore

/// Read paths compared against the HomeCoreTesting in-memory oracles over `SampleHome`.
final class OracleTests: XCTestCase {
    func testMigrationsCreateEveryTable() async throws {
        let store = try Fixture.empty()
        let names = try await store.database.read { d in try String.fetchAll(d, sql: "SELECT name FROM sqlite_master WHERE type IN ('table')") }
        for t in RecordType.allCases { XCTAssertTrue(names.contains(t.tableName), t.tableName) }
        for t in ["sync_state", "sync_record_meta", "sync_outbox", "sync_orphan", "calendar_event_cache", "attachment_local",
                  "map_snapshot_cache", "notification_snooze", "app_meta", "search_fts"] {
            XCTAssertTrue(names.contains(t), t)
        }
        let applied = try await store.database.read { d in try String.fetchAll(d, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid") }
        XCTAssertEqual(applied, ["v1_core", "v1_local", "v1_search"])
    }

    func testEveryModelRoundTrips() async throws {
        let f = try await Fixture.sample()
        let snap = f.oracle.store.read { $0 }
        try await f.store.database.read { d in
            func check<M: DatabaseModel>(_ t: M.Type, _ expected: [UUID: M]) throws {
                let got = try M.fetchAll(d, includeDeleted: true)
                XCTAssertEqual(got.count, expected.count, "\(M.recordType)")
                for g in got { XCTAssertEqual(g, expected[g.id], "\(M.recordType) \(g.id)") }
            }
            try check(Property.self, snap.properties); try check(Level.self, snap.levels); try check(Space.self, snap.spaces)
            try check(Opening.self, snap.openings); try check(Person.self, snap.people); try check(StorageSpot.self, snap.spots)
            try check(HomeMeasurement.self, snap.measurements); try check(Thing.self, snap.things); try check(Chore.self, snap.chores)
            try check(Project.self, snap.projects); try check(CostLineItem.self, snap.lineItems); try check(InventoryItem.self, snap.inventory)
        }
    }

    func testListQueriesMatchOracle() async throws {
        let f = try await Fixture.sample()
        let pid = f.pid
        let kitchen = Scope.space(SampleHome.kitchenId, level: SampleHome.firstFloorId)
        for q in [ChoreQuery(propertyId: pid), ChoreQuery(propertyId: pid, scope: kitchen), ChoreQuery(propertyId: pid, scope: .property),
                  ChoreQuery(propertyId: pid, levelId: SampleHome.basementId), ChoreQuery(propertyId: pid, linkedThingId: SampleHome.furnaceId),
                  ChoreQuery(propertyId: pid, assigneeId: SampleHome.mattId), ChoreQuery(propertyId: pid, includeClosed: true, includePaused: false)] {
            let a = try await f.store.chores.chores(q), b = try await f.oracle.chores.chores(q)
            XCTAssertEqual(a, b, "\(q)")
        }
        for q in [ProjectQuery(propertyId: pid), .future(pid), .past(pid), ProjectQuery(propertyId: pid, scope: kitchen),
                  ProjectQuery(propertyId: pid, levelId: SampleHome.secondFloorId)] {
            let a = try await f.store.projects.projects(q), b = try await f.oracle.projects.projects(q)
            XCTAssertEqual(a, b)
        }
        for q in [ThingQuery(propertyId: pid), ThingQuery(propertyId: pid, scope: kitchen), ThingQuery(propertyId: pid, category: .appliance),
                  ThingQuery(propertyId: pid, ownership: .planned), ThingQuery(propertyId: pid, levelId: SampleHome.firstFloorId)] {
            let a = try await f.store.things.things(q), b = try await f.oracle.things.things(q)
            XCTAssertEqual(a, b)
        }
        for q in [InventoryQuery(propertyId: pid), InventoryQuery(propertyId: pid, spotId: SampleHome.shelfId),
                  InventoryQuery(propertyId: pid, kind: .clothing), InventoryQuery(propertyId: pid, ownerId: SampleHome.mattId),
                  InventoryQuery(propertyId: pid, lowOnly: true), InventoryQuery(propertyId: pid, levelId: SampleHome.basementId)] {
            let a = try await f.store.inventory.items(q), b = try await f.oracle.inventory.items(q)
            XCTAssertEqual(a, b)
        }
        let levels = try await f.store.plan.levels(property: pid)
        let oracleLevels = try await f.oracle.plan.levels(property: pid)
        XCTAssertEqual(levels, oracleLevels)
        for l in levels {
            let g = try await f.store.plan.geometry(level: l.id), o = try await f.oracle.plan.geometry(level: l.id)
            XCTAssertEqual(g.spaces, o.spaces)
            XCTAssertEqual(Set(g.openings), Set(o.openings))
        }
        let people = try await f.store.people.people(property: pid)
        let oraclePeople = try await f.oracle.people.people(property: pid)
        XCTAssertEqual(people, oraclePeople)
        let dp = try await f.store.measurements.deliveryPaths(property: pid)
        let odp = try await f.oracle.measurements.deliveryPaths(property: pid)
        XCTAssertEqual(dp, odp)
        let km = try await f.store.measurements.measurements(space: SampleHome.kitchenId)
        let okm = try await f.oracle.measurements.measurements(space: SampleHome.kitchenId)
        XCTAssertEqual(km, okm)
        let fit = try await f.store.things.fit(for: SampleHome.plannedFridgeId)
        let ofit = try await f.oracle.things.fit(for: SampleHome.plannedFridgeId)
        XCTAssertEqual(fit, ofit)
        XCTAssertEqual(fit.first?.result.overall, .noFit)
        let current = try await f.store.plan.currentProperty()
        XCTAssertEqual(current?.id, pid)
    }

    func testRollupsMatchOracle() async throws {
        let f = try await Fixture.sample()
        for l in [SampleHome.basementId, SampleHome.firstFloorId, SampleHome.secondFloorId, SampleHome.outsideId] {
            let rooms = try await f.store.database.read { try RollupQueries.rooms($0, level: l) }
            let oRooms = try await first(f.oracle.rollups.observeRooms(level: l))
            XCTAssertEqual(rooms, oRooms)
            let floor = try await first(f.store.rollups.observeFloor(level: l))
            let oFloor = try await first(f.oracle.rollups.observeFloor(level: l))
            XCTAssertEqual(floor, oFloor)
        }
        let p = try await first(f.store.rollups.observeProperty(f.pid))
        let o = try await first(f.oracle.rollups.observeProperty(f.pid))
        XCTAssertEqual(p, o)
        // Bathroom remodel: line items drive spent; variance vs 11,000 estimate.
        XCTAssertEqual(p.total.lifetimeCents, 12_100_00)
        XCTAssertEqual(p.total.varianceCents, 1_100_00)
        XCTAssertEqual(p.wholeHouse.ideaCents, 8_000_00)
    }

    func testLensStatsMatchOracle() async throws {
        let f = try await Fixture.sample()
        let snap = f.oracle.store.read { $0 }
        for l in [SampleHome.basementId, SampleHome.firstFloorId, SampleHome.secondFloorId, SampleHome.outsideId] {
            let s = try await first(f.store.lensStats.observeStats(level: l, today: today))
            let o = InMemoryLensStatsService.compute(snap, level: l, today: today)
            XCTAssertEqual(s.spaces, o.spaces, "spaces \(l)")
            XCTAssertEqual(s.levelScope, o.levelScope, "levelScope \(l)")
            XCTAssertEqual(s.floorTotal, o.floorTotal, "floorTotal \(l)")
            XCTAssertEqual(s.propertyScope, o.propertyScope, "propertyScope \(l)")
            XCTAssertEqual(s.propertyTotal, o.propertyTotal, "propertyTotal \(l)")
            XCTAssertEqual(s.thingPins, o.thingPins)
            XCTAssertEqual(Set(s.spotPins), Set(o.spotPins))
            XCTAssertEqual(s.roomCount, o.roomCount)
            XCTAssertEqual(s.interiorAreaSqIn, o.interiorAreaSqIn, accuracy: 0.001)
        }
    }

    func testInventoryQueriesMatchOracle() async throws {
        let f = try await Fixture.sample()
        let ids = [UUID](SampleHome.snapshot().inventory.keys)
        let loc = try await f.store.inventory.locations(of: ids)
        let oLoc = try await f.oracle.inventory.locations(of: ids)
        XCTAssertEqual(loc, oLoc)
        let coat = loc.first { $0.name == "Winter coat" }
        XCTAssertEqual(coat?.displayPath, "Storage › Shelf 2 › Bin Winter – Matt")
        XCTAssertEqual(coat?.owner, "Matt")
        for date in [today, LocalDate(2026, 4, 1)] {
            let swap = try await first(f.store.inventory.observeSeasonalSwap(property: f.pid, on: date))
            let oSwap = try await first(f.oracle.inventory.observeSeasonalSwap(property: f.pid, on: date))
            XCTAssertEqual(swap, oSwap)
        }
        let shop = try await first(f.store.inventory.observeShoppingList(property: f.pid, on: today))
        let oShop = try await first(f.oracle.inventory.observeShoppingList(property: f.pid, on: today))
        XCTAssertEqual(Set(shop), Set(oShop))
        let tree = try await first(f.store.inventory.observeSpotTree(space: SampleHome.storageId))
        let oTree = try await first(f.oracle.inventory.observeSpotTree(space: SampleHome.storageId))
        XCTAssertEqual(tree, oTree)
        XCTAssertEqual(tree.first?.subtreeItemCount, 3)
    }

    func testSearchMatchesOracleAndSpec() async throws {
        let f = try await Fixture.sample()
        for q in ["winter co", "16x25", "furnace", "kitchen", "matt", "fridge", "trash", "bath", "shelf", "zzz nothing", "tile"] {
            let a = try await f.store.search.search(q, property: f.pid)
            let b = try await f.oracle.search.search(q, property: f.pid)
            XCTAssertEqual(Set(a.map(\.id)).isSuperset(of: Set(b.map(\.id))) || Set(a.map(\.id)) == Set(b.map(\.id)), true, "\(q): \(a.map(\.title)) vs \(b.map(\.title))")
        }
        // AC-SES-1: where-is answer card.
        let hits = try await f.store.search.search("winter co", property: f.pid)
        XCTAssertEqual(hits.first?.title, "Winter coat")
        XCTAssertEqual(hits.first?.location, "Storage › Shelf 2 › Bin Winter – Matt · Basement")
        XCTAssertEqual(hits.first?.people, "Matt")
        XCTAssertTrue(hits.first?.qualifiesForWhereIsCard ?? false)
        // AC-SES-2: template attribute values.
        let furnace = try await f.store.search.search("16x25", property: f.pid)
        XCTAssertTrue(furnace.contains { $0.entityId == SampleHome.furnaceId })
        // AND then OR fallback.
        let or = try await f.store.search.search("furnace zzzz", property: f.pid)
        XCTAssertTrue(or.contains { $0.entityId == SampleHome.furnaceId })
        // Punctuation only → empty.
        let punct = try await f.store.search.search("\"*()", property: f.pid)
        XCTAssertTrue(punct.isEmpty)
        // AC-SES-4: renaming the room reindexes spots and items in the same save.
        try await f.store.plan.renameSpace(SampleHome.storageId, to: "Loft")
        let renamed = try await f.store.search.search("winter coat", property: f.pid)
        XCTAssertEqual(renamed.first?.location, "Loft › Shelf 2 › Bin Winter – Matt · Basement")
        // FR-SES-08: deleted items are not returned.
        try await f.store.inventory.delete(SampleHome.id(120))
        let gone = try await f.store.search.search("winter coat", property: f.pid)
        XCTAssertFalse(gone.contains { $0.entityId == SampleHome.id(120) })
        // AC-SES-3: receipt OCR text on a project.
        let receipt = try tmpFile("receipt", ext: "pdf")
        _ = try await f.store.attachments.add(AttachmentDraft(fileURL: receipt, kind: .receipt, uti: "com.adobe.pdf", ocrText: "Sherwin Williams total 84.20"),
                                              ownerType: .project, ownerId: SampleHome.paintId, property: f.pid)
        let sherwin = try await f.store.search.search("sherwin", property: f.pid)
        XCTAssertEqual(sherwin.first?.entityId, SampleHome.paintId)
        // Rebuild keeps results.
        try await f.store.search.rebuildIndex()
        let again = try await f.store.search.search("sherwin", property: f.pid)
        XCTAssertEqual(again.first?.entityId, SampleHome.paintId)
    }

    func testDiagnosticsCountsMatchOracle() async throws {
        let f = try await Fixture.sample()
        let c = try await f.store.diagnostics.counts(property: f.pid)
        let o = try await f.oracle.diagnostics.counts(property: f.pid)
        XCTAssertEqual(c.levels, o.levels)
        XCTAssertEqual(c.spacesBySource, o.spacesBySource)
        XCTAssertEqual(c.itemsByKind, o.itemsByKind)
        XCTAssertEqual(c.choresWithReminder, o.choresWithReminder)
        XCTAssertEqual(c.doneProjectsWithActual, o.doneProjectsWithActual)
        // AC-SES-9: counts-only export contains no user content.
        let url = try await f.store.diagnostics.exportDiagnostics(property: f.pid)
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [url]
        for file in files where !file.hasDirectoryPath {
            let text = String(decoding: (try? Data(contentsOf: file)) ?? Data(), as: UTF8.self)
            for secret in ["Maple", "Matt", "Kitchen", "furnace", "Winter coat"] { XCTAssertFalse(text.contains(secret), "\(secret) in \(file.lastPathComponent)") }
        }
    }
}

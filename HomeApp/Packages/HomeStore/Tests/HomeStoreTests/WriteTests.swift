import Foundation
import XCTest
import HomeCore
import HomeCoreTesting
import PlanKit
@testable import HomeStore

/// Write paths: the same operations on the GRDB store and the in-memory oracle must leave equivalent state.
final class WriteTests: XCTestCase {
    func testChoreLifecycleMirrorsOracle() async throws {
        let f = try await Fixture.sample()
        let kitchen = Scope.space(SampleHome.kitchenId, level: SampleHome.firstFloorId)
        let draft = ChoreDraft(propertyId: f.pid, scope: kitchen, title: "Wipe counters", repeatRule: .weekly([2, 5]), startOn: today, dueMinutes: 600)
        let a = try await f.store.chores.create(draft), b = try await f.oracle.chores.create(draft)
        XCTAssertEqual(a.nextDueOn, b.nextDueOn)
        let doneA = try await f.store.chores.complete(a.id, by: SampleHome.mattId, at: clock.now)
        let doneB = try await f.oracle.chores.complete(b.id, by: SampleHome.mattId, at: clock.now)
        XCTAssertEqual(doneA.doneOn, doneB.doneOn); XCTAssertEqual(doneA.dueOn, doneB.dueOn)
        try await f.store.chores.skip(a.id, at: clock.now); try await f.oracle.chores.skip(b.id, at: clock.now)
        var ca = try await f.store.chores.chore(a.id), cb = try await f.oracle.chores.chore(b.id)
        XCTAssertEqual(ca?.nextDueOn, cb?.nextDueOn)
        let historyA = try await f.store.chores.completions(chore: a.id)
        XCTAssertEqual(historyA.count, 2)
        // Rule edit recomputes next due from the latest completion.
        ca!.repeatRule = .everyNDays(10); cb!.repeatRule = .everyNDays(10)
        try await f.store.chores.update(ca!); try await f.oracle.chores.update(cb!)
        ca = try await f.store.chores.chore(a.id); cb = try await f.oracle.chores.chore(b.id)
        XCTAssertEqual(ca?.nextDueOn, cb?.nextDueOn)
        try await f.store.chores.reschedule(a.id, to: today.adding(days: 3))
        try await f.store.chores.setPaused(a.id, true)
        ca = try await f.store.chores.chore(a.id)
        XCTAssertEqual(ca?.nextDueOn, today.adding(days: 3)); XCTAssertEqual(ca?.isPaused, true)
        // One-off completion closes.
        _ = try await f.store.chores.complete(SampleHome.gutterId, by: nil, at: clock.now)
        let gutter = try await f.store.chores.chore(SampleHome.gutterId)
        XCTAssertNotNil(gutter?.closedAt); XCTAssertNil(gutter?.nextDueOn)
        // Turn into project.
        let p = try await f.store.chores.turnIntoProject(SampleHome.filterId)
        XCTAssertEqual(p.spawnedFromChoreId, SampleHome.filterId); XCTAssertEqual(p.status, .idea)
        // Calendar link.
        let link = ChoreCalendarLink(choreId: a.id, propertyId: f.pid, ownerDeviceId: "dev", calendarTitle: "Home", eventMode: .series)
        try await f.store.chores.saveCalendarLink(link)
        let gotLink = try await f.store.chores.calendarLink(chore: a.id)
        XCTAssertEqual(gotLink?.ownerDeviceId, "dev")
        try await f.store.chores.deleteCalendarLink(chore: a.id)
        let noLink = try await f.store.chores.calendarLink(chore: a.id)
        XCTAssertNil(noLink)
        try await f.store.chores.delete(a.id)
        let deleted = try await f.store.chores.chore(a.id)
        XCTAssertNil(deleted)
    }

    func testProjectLifecycleAndRollup() async throws {
        let f = try await Fixture.sample()
        let draft = ProjectDraft(propertyId: f.pid, scope: .level(SampleHome.firstFloorId), title: "Refinish floors", status: .planned, estCost: Money(cents: 3_000_00))
        let a = try await f.store.projects.create(draft), b = try await f.oracle.projects.create(draft)
        try await f.store.projects.setStatus(a.id, .inProgress); try await f.oracle.projects.setStatus(b.id, .inProgress)
        let li = { (pid: UUID) in CostLineItem(propertyId: f.pid, projectId: pid, label: "Sander rental", amount: Money(cents: 250_00), kind: .other, hours: 4) }
        try await f.store.projects.upsertLineItem(li(a.id)); try await f.oracle.projects.upsertLineItem(li(b.id))
        let fa = try await first(f.store.rollups.observeFloor(level: SampleHome.firstFloorId))
        let fb = try await first(f.oracle.rollups.observeFloor(level: SampleHome.firstFloorId))
        XCTAssertEqual(fa, fb)
        let receipt = try tmpFile("pdf-bytes", ext: "pdf")
        try await f.store.projects.markDone(a.id, actual: Money(cents: 2_800_00), completedOn: today, hours: 12,
                                            receipt: AttachmentDraft(fileURL: receipt, kind: .receipt, uti: "com.adobe.pdf"))
        try await f.oracle.projects.markDone(b.id, actual: Money(cents: 2_800_00), completedOn: today, hours: 12, receipt: nil)
        let pa = try await f.store.projects.project(a.id), pb = try await f.oracle.projects.project(b.id)
        XCTAssertEqual(pa?.status, .done); XCTAssertEqual(pa?.completedOn, pb?.completedOn); XCTAssertEqual(pa?.actualCost, pb?.actualCost)
        let atts = try await f.store.attachments.attachments(ownerType: .project, ownerId: a.id)
        XCTAssertEqual(atts.count, 1)
        let url = await f.store.attachments.fileURL(for: atts[0])
        XCTAssertNotNil(url)
        XCTAssertEqual(atts[0].sha256, SHA256.hex(Data("pdf-bytes".utf8)))
        XCTAssertEqual(SHA256.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        try await f.store.projects.reopen(a.id)
        let reopened = try await f.store.projects.project(a.id)
        XCTAssertEqual(reopened?.status, .inProgress); XCTAssertEqual(reopened?.actualCost, Money(cents: 2_800_00))
        let lines = try await f.store.projects.lineItems(project: a.id)
        try await f.store.projects.deleteLineItem(lines[0].id)
        let remaining = try await f.store.projects.lineItems(project: a.id)
        XCTAssertTrue(remaining.isEmpty)
        do { try await f.store.projects.upsertLineItem(CostLineItem(propertyId: f.pid, projectId: a.id, label: "x", amount: Money(cents: -1))); XCTFail() }
        catch { }
    }

    func testInventoryWritesMirrorOracle() async throws {
        let f = try await Fixture.sample()
        let storage = Scope.space(SampleHome.storageId, level: SampleHome.basementId)
        let draft = InventoryDraft(propertyId: f.pid, kind: .stored, name: "Light bulbs", scope: .property, storageSpotId: SampleHome.shelfId,
                                   quantity: 3, unit: "ea", lowThreshold: 2)
        let a = try await f.store.inventory.create(draft), b = try await f.oracle.inventory.create(draft)
        XCTAssertEqual(a.scope, storage); XCTAssertEqual(a.scope, b.scope)
        try await f.store.inventory.adjustQuantity(a.id, by: -1); try await f.oracle.inventory.adjustQuantity(b.id, by: -1)
        let ia = try await f.store.inventory.item(a.id), ib = try await f.oracle.inventory.item(b.id)
        XCTAssertEqual(ia?.isLow, true); XCTAssertEqual(ia?.isLow, ib?.isLow)
        // New spot in the kitchen; move items there; scope follows the spot's room.
        let spot = StorageSpot(propertyId: f.pid, spaceId: SampleHome.kitchenId, name: "Pantry shelf", pin: Vec2(20 * 12, 5 * 12))
        try await f.store.inventory.saveSpot(spot)
        try await f.store.inventory.move([a.id, SampleHome.id(124)], to: spot.id)
        let moved = try await f.store.inventory.item(a.id)
        XCTAssertEqual(moved?.scope, .space(SampleHome.kitchenId, level: SampleHome.firstFloorId))
        // Cycle guard (§11.2).
        do { try await f.store.inventory.reparentSpot(SampleHome.shelfId, to: SampleHome.winterBinId); XCTFail("cycle") }
        catch RepositoryError.cycle {}
        do { try await f.store.inventory.reparentSpot(SampleHome.winterBinId, to: spot.id); XCTFail("cross-room") }
        catch RepositoryError.cycle {}
        // Delete the shelf subtree; its items go to the kitchen spot.
        try await f.store.inventory.deleteSpot(SampleHome.shelfId, moveItemsTo: spot.id)
        try await f.oracle.inventory.deleteSpot(SampleHome.shelfId, moveItemsTo: nil)
        let coat = try await f.store.inventory.item(SampleHome.id(120))
        XCTAssertEqual(coat?.storageSpotId, spot.id)
        let binGone = try await f.store.inventory.spot(SampleHome.winterBinId)
        XCTAssertNil(binGone)
        try await f.store.inventory.applySwap(itemIds: [SampleHome.id(120)], inRotation: true)
        let swapped = try await f.store.inventory.item(SampleHome.id(120))
        XCTAssertEqual(swapped?.inRotation, true)
    }

    func testOutboxUnionsChangedFieldsAndSyncOriginSkips() async throws {
        let f = try await Fixture.sample()
        var t = try await f.store.things.thing(SampleHome.furnaceId)!
        t.name = "Furnace (Lennox)"
        t.attributes["merv"] = 13
        try await f.store.things.update(t)
        var e = try await f.store.sync.outboxEntry(RecordRef(.thing, t.id))
        XCTAssertEqual(e?.op, .save)
        XCTAssertTrue(e!.changedFields.isSuperset(of: ["name", "attributes_json", "attributes_json.merv"]), "\(e!.changedFields)")
        XCTAssertFalse(e!.changedFields.contains("brand"))
        XCTAssertEqual(e?.zoneName, "property-" + f.pid.uuidString.lowercased())
        let v1 = e!.localVersion
        t.brand = "Lennox"
        try await f.store.things.update(t)
        e = try await f.store.sync.outboxEntry(RecordRef(.thing, t.id))
        XCTAssertEqual(e!.localVersion, v1 + 1)
        XCTAssertTrue(e!.changedFields.isSuperset(of: ["name", "brand"]))
        // Seeding used origin .sync: nothing else pending.
        let count = try await f.store.sync.outboxCount()
        XCTAssertEqual(count, 1)
    }

    func testUpdateSpacesRejectsOverlapAndWelds() async throws {
        let f = try await Fixture.sample()
        var kitchen = try await f.store.plan.space(SampleHome.kitchenId)!
        kitchen.polygon = Polygon(rect: Rect(x: 10 * 12, y: 0, width: 20 * 12, height: 14 * 12))   // into the living room
        do { try await f.store.plan.updateSpaces([.update(kitchen)]); XCTFail("overlap") }
        catch RepositoryError.overlap(let ids) { XCTAssertTrue(ids.contains(SampleHome.kitchenId)) }
        let unchanged = try await f.store.plan.space(SampleHome.kitchenId)
        XCTAssertEqual(unchanged?.polygon, Polygon(rect: Rect(x: 16 * 12, y: 0, width: 14 * 12, height: 14 * 12)))
        // A new room drawn 1 in off the shared wall is welded onto it.
        let pantry = Space(propertyId: f.pid, levelId: SampleHome.firstFloorId, name: "Pantry", spaceType: .closet,
                           polygon: Polygon(rect: Rect(x: 40 * 12 + 1, y: 0, width: 5 * 12, height: 14 * 12)))
        try await f.store.plan.updateSpaces([.insert(pantry)])
        let welded = try await f.store.plan.space(pantry.id)!
        let dining = try await f.store.plan.space(SampleHome.diningId)!
        XCTAssertEqual(welded.polygon.bounds.minX, dining.polygon.bounds.maxX, accuracy: 0.01, "shared wall coincides")
        // Delete a room: items move to the floor; spot soft-deleted.
        try await f.store.plan.deleteSpace(SampleHome.storageId, reassignItemsTo: .level(SampleHome.basementId))
        try await f.oracle.plan.deleteSpace(SampleHome.storageId, reassignItemsTo: .level(SampleHome.basementId))
        let items = try await f.store.inventory.items(InventoryQuery(propertyId: f.pid, scope: .level(SampleHome.basementId)))
        let oItems = try await f.oracle.inventory.items(InventoryQuery(propertyId: f.pid, scope: .level(SampleHome.basementId)))
        XCTAssertEqual(items.map(\.id), oItems.map(\.id))
        XCTAssertTrue(items.allSatisfy { $0.storageSpotId == nil })
    }

    func testPlanCommitWeldsAndAcceptsSuggestions() async throws {
        let store = try Fixture.empty()
        let prop = Property(name: "New", createdAt: clock.now, updatedAt: clock.now)
        try await store.plan.saveProperty(prop)
        let a = SpaceDraft(name: "Living", spaceType: .living, polygon: Polygon(rect: Rect(x: 0, y: 0, width: 180, height: 144)), source: .rough)
        let b = SpaceDraft(name: "Kitchen", spaceType: .kitchen, polygon: Polygon(rect: Rect(x: 181.5, y: 0, width: 144, height: 144)), source: .rough)
        let fridge = SuggestedThing(spaceTempId: b.tempId, category: .appliance, templateKey: "refrigerator", name: "Refrigerator")
        let tv = SuggestedThing(spaceTempId: a.tempId, category: .electronic, templateKey: "tv", name: "TV")
        let door = OpeningDraft(spaceTempId: a.tempId, kind: .door, segment: Segment(Vec2(20, 144), Vec2(56, 144)), isExteriorDoor: true)
        let m = MeasurementDraft(label: "Front door", kind: .door, spaceTempId: a.tempId, openingTempId: door.tempId,
                                 dims: Dims3(width: 36, height: 80), isDeliveryPath: true, source: .roomplan)
        let draft = PlanDraft(levels: [LevelDraft(name: "1st Floor", spaces: [a, b], openings: [door], suggestedThings: [fridge, tv], measurements: [m])],
                              source: .roomplan)
        let ids = try await store.planCommitter.commit(draft, into: prop.id, acceptedSuggestions: [fridge.tempId])
        XCTAssertEqual(ids.count, 1)
        let g = try await store.plan.geometry(level: ids[0])
        XCTAssertEqual(g.spaces.count, 2)
        let kitchen = g.spaces.first { $0.name == "Kitchen" }!, living = g.spaces.first { $0.name == "Living" }!
        XCTAssertEqual(kitchen.polygon.bounds.minX, living.polygon.bounds.maxX, accuracy: 0.01, "welded onto a shared wall")
        XCTAssertEqual(g.openings.count, 1); XCTAssertEqual(g.openings[0].source, .roomplan)
        let things = try await store.things.things(ThingQuery(propertyId: prop.id))
        XCTAssertEqual(things.map(\.name), ["Refrigerator"])
        let paths = try await store.measurements.deliveryPaths(property: prop.id)
        XCTAssertEqual(paths.count, 1)
        let p = try await store.plan.currentProperty()
        XCTAssertEqual(p?.defaultLevelId, ids[0])
        let pending = try await store.sync.outboxCount()
        XCTAssertEqual(pending, 1 + 1 + 2 + 1 + 1 + 1, "property, level, 2 spaces, opening, measurement, thing")
        do { _ = try await store.planCommitter.commit(draft, into: UUID(), acceptedSuggestions: []); XCTFail() } catch {}
    }

    func testRecentlyDeletedRestoreRehomesAndPurge() async throws {
        let f = try await Fixture.sample()
        try await f.store.chores.delete(SampleHome.dishesId)
        try await f.store.plan.deleteSpace(SampleHome.kitchenId, reassignItemsTo: .level(SampleHome.firstFloorId))
        try await f.oracle.chores.delete(SampleHome.dishesId)
        try await f.oracle.plan.deleteSpace(SampleHome.kitchenId, reassignItemsTo: .level(SampleHome.firstFloorId))
        let list = try await f.store.recentlyDeleted.deleted(property: f.pid)
        let oList = try await f.oracle.recentlyDeleted.deleted(property: f.pid)
        XCTAssertEqual(Set(list.map(\.ref)), Set(oList.map(\.ref)))
        // The chore was deleted while in the kitchen, so it was re-scoped to the floor at room delete.
        try await f.store.recentlyDeleted.restore(RecordRef(.chore, SampleHome.dishesId))
        let dishes = try await f.store.chores.chore(SampleHome.dishesId)
        XCTAssertEqual(dishes?.scope, .level(SampleHome.firstFloorId))
        // Restore the room; purge a project with line items and an attachment.
        try await f.store.recentlyDeleted.restore(RecordRef(.space, SampleHome.kitchenId))
        let kitchen = try await f.store.plan.space(SampleHome.kitchenId)
        XCTAssertNotNil(kitchen)
        try await f.store.projects.delete(SampleHome.bathRemodelId)
        try await f.store.recentlyDeleted.purge(RecordRef(.project, SampleHome.bathRemodelId))
        let lines = try await f.store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM cost_line_item WHERE project_id = ?", arguments: [SampleHome.bathRemodelId.db]) }
        XCTAssertEqual(lines, 0)
        let deleteOps = try await f.store.sync.outbox().filter { $0.op == .delete }
        XCTAssertEqual(Set(deleteOps.map(\.recordType)), [.project, .costLineItem])
        XCTAssertEqual(deleteOps.count, 5)
        // Purge a room: soft-deleted items still pointing at it are re-homed first (scope CHECK), children cascade.
        try await f.store.things.delete(SampleHome.tvId)
        try await f.store.plan.deleteSpace(SampleHome.livingId, reassignItemsTo: .property)
        try await f.store.recentlyDeleted.purge(RecordRef(.space, SampleHome.livingId))
        // purgeExpired with a future cutoff removes every remaining soft-deleted row.
        let n = try await f.store.recentlyDeleted.purgeExpired(before: clock.now.addingTimeInterval(86_400))
        XCTAssertGreaterThan(n, 0)
        let after = try await f.store.recentlyDeleted.deleted(property: f.pid)
        XCTAssertTrue(after.isEmpty)
        let tv = try await f.store.database.read { try Thing.fetchOne($0, id: SampleHome.tvId) }
        XCTAssertNil(tv)
    }

    func testObservationYieldsCurrentThenChanges() async throws {
        let f = try await Fixture.sample()
        let stream = f.store.chores.observeChores(ChoreQuery(propertyId: f.pid, scope: .property))
        var it = stream.makeAsyncIterator()
        let initial = await it.next()
        XCTAssertEqual(initial?.count, 2)
        _ = try await f.store.chores.create(ChoreDraft(propertyId: f.pid, scope: .property, title: "Check smoke alarms", startOn: today))
        let next = await it.next()
        XCTAssertEqual(next?.count, 3)
        // Events are published after commit.
        let bus = f.store.database.bus
        let events = bus.events
        var ei = events.makeAsyncIterator()
        _ = try await f.store.chores.create(ChoreDraft(propertyId: f.pid, scope: .property, title: "Salt the walk", startOn: today))
        let e = await ei.next()
        if case .created(.chore) = e {} else { XCTFail("\(String(describing: e))") }
    }

    func testSettingsPersistAndObserve() async throws {
        let store = try Fixture.empty()
        var s = await store.settings.load()
        XCTAssertEqual(s.defaultAllDayMinutes, 540)
        s.lastLens = .budget; s.deviceNickname = "Kitchen iPad"
        await store.settings.save(s)
        let loaded = await store.settings.load()
        XCTAssertEqual(loaded, s)
        let observed = try await first(store.settings.observe())
        XCTAssertEqual(observed.lastLens, .budget)
    }

    func testExportWritesElevenCSVsAndReadme() async throws {
        let f = try await Fixture.sample()
        let url = try await f.store.export.exportCSV(property: f.pid, options: ExportOptions())
        #if canImport(Darwin)
        XCTAssertEqual(url.pathExtension, "zip")
        #else
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        XCTAssertEqual(Set(names), Set(CSVExporter.fileNames + ["README.txt"]))
        XCTAssertEqual(url.lastPathComponent, "Home-Export-2026-09-29")
        let projects = try Data(contentsOf: url.appendingPathComponent("projects.csv"))
        XCTAssertEqual(Array(projects.prefix(3)), [0xEF, 0xBB, 0xBF], "UTF-8 BOM")
        let text = String(decoding: projects, as: UTF8.self)
        XCTAssertTrue(text.contains("spent_effective"))
        XCTAssertTrue(text.contains("Bathroom remodel") && text.contains("12100.00"))
        XCTAssertTrue(text.contains("\r\n"))
        let chores = String(decoding: try Data(contentsOf: url.appendingPathComponent("chores.csv")), as: UTF8.self)
        XCTAssertTrue(chores.contains("Every 90 days after done"))
        let budget = String(decoding: try Data(contentsOf: url.appendingPathComponent("budget_summary.csv")), as: UTF8.self)
        XCTAssertTrue(budget.contains("Total"))
        #endif
    }

    func testLevelRulesAndDefaultLevel() async throws {
        let f = try await Fixture.sample()
        do {
            try await f.store.plan.saveLevel(Level(propertyId: f.pid, name: "Yard 2", kind: .exterior, sortOrder: 101))
            XCTFail("second exterior")
        } catch RepositoryError.invalid {}
        try await f.store.plan.setDefaultLevel(SampleHome.secondFloorId, property: f.pid)
        let p = try await f.store.plan.currentProperty()
        XCTAssertEqual(p?.defaultLevelId, SampleHome.secondFloorId)
        try await f.store.plan.deleteLevel(SampleHome.secondFloorId, reassignItemsTo: .property)
        let levels = try await f.store.plan.levels(property: f.pid)
        XCTAssertFalse(levels.contains { $0.id == SampleHome.secondFloorId })
        XCTAssertEqual(levels.defaultLevel(preferred: p?.defaultLevelId)?.id, SampleHome.firstFloorId)
        let detector = try await f.store.things.thing(SampleHome.detectorId)
        XCTAssertEqual(detector?.scope, .property)
    }
}

final class FileDatabaseTests: XCTestCase {
    func testLiveStoreUsesWALAndPersistsAcrossOpen() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("home-live-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = UserDefaults(suiteName: "homestore.live.\(UUID().uuidString)")!
        do {
            let store = try HomeStore.live(directory: dir, clock: clock, defaults: defaults)
            let mode = try await store.database.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
            XCTAssertEqual(mode?.lowercased(), "wal")
            try await store.plan.saveProperty(Property(id: SampleHome.propertyId, name: "Persisted", createdAt: clock.now, updatedAt: clock.now))
        }
        let reopened = try HomeStore.live(directory: dir, clock: clock, defaults: defaults)
        let p = try await reopened.plan.currentProperty()
        XCTAssertEqual(p?.name, "Persisted")
        let pending = try await reopened.sync.outboxCount()
        XCTAssertEqual(pending, 1, "the outbox survives an app kill (FR-SYN-02)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("home.sqlite").path))
    }
}

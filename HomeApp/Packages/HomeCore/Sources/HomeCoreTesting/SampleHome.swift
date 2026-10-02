import Foundation
import HomeCore
import PlanKit

/// Deterministic sample data for previews and tests: a two-story house with a basement and yard,
/// two housemates, chores (one overdue), projects in every status, things, measurements and inventory.
public enum SampleHome {
    /// Stable UUIDs: `00000000-0000-0000-0000-0000000000NN`.
    public static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

    public static let propertyId = id(1)
    public static let basementId = id(10), firstFloorId = id(11), secondFloorId = id(12), outsideId = id(13)
    public static let livingId = id(20), kitchenId = id(21), diningId = id(22), hallId = id(23), halfBathId = id(24), laundryId = id(25)
    public static let primaryId = id(30), bedroom2Id = id(31), bathId = id(32), hall2Id = id(33)
    public static let utilityId = id(40), storageId = id(41)
    public static let mattId = id(50), alexId = id(51)
    public static let fridgeId = id(60), furnaceId = id(61), tvId = id(62), sofaId = id(63), plannedFridgeId = id(64), detectorId = id(65)
    public static let fridgeOpeningId = id(70), frontDoorId = id(71), frontDoorOpeningId = id(72)
    public static let shelfId = id(80), winterBinId = id(81)
    public static let dishesId = id(90), trashId = id(91), filterId = id(92), batteryId = id(93), gutterId = id(94)
    public static let paintId = id(100), deckId = id(101), bathRemodelId = id(102), fridgeProjectId = id(103)

    static let ft = 12.0
    static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Polygon {
        Polygon(rect: Rect(x: x * ft, y: y * ft, width: w * ft, height: h * ft))
    }

    /// Builds the snapshot relative to `today` (due dates shift so there is always something due/overdue).
    public static func snapshot(today: LocalDate = LocalDate(2026, 9, 29), now: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> InMemorySnapshot {
        var s = InMemorySnapshot()
        let t = now
        let pid = propertyId
        s.properties[pid] = Property(id: pid, name: "Maple Street",
                                     address: PostalAddressLite(line: "12 Maple St", locality: "Springfield", region: "IL", postalCode: "62701", countryCode: "US"),
                                     latitude: 39.7817, longitude: -89.6501, yearBuilt: 1978, approxSqFt: 1900,
                                     defaultLevelId: firstFloorId, createdAt: t, updatedAt: t)
        for (lid, name, kind, order) in [(basementId, "Basement", Level.Kind.basement, -1), (firstFloorId, "1st Floor", .floor, 0),
                                         (secondFloorId, "2nd Floor", .floor, 1), (outsideId, "Outside", .exterior, Level.exteriorSortOrder)] {
            s.levels[lid] = Level(id: lid, propertyId: pid, name: name, kind: kind, sortOrder: order,
                                  georef: kind == .exterior ? GeoReference(originLat: 39.7817, originLon: -89.6501) : nil, createdAt: t, updatedAt: t)
        }
        func space(_ sid: UUID, _ level: UUID, _ name: String, _ type: SpaceType, _ poly: Polygon, exterior: Bool = false,
                   source: Space.Source = .blocks, color: String? = nil) {
            s.spaces[sid] = Space(id: sid, propertyId: pid, levelId: level, name: name, spaceType: type, isExterior: exterior,
                                  polygon: poly, source: source, colorHex: color, createdAt: t, updatedAt: t)
        }
        // 1st floor: 40 × 30 ft.
        space(livingId, firstFloorId, "Living Room", .living, rect(0, 0, 16, 18))
        space(kitchenId, firstFloorId, "Kitchen", .kitchen, rect(16, 0, 14, 14))
        space(diningId, firstFloorId, "Dining Room", .dining, rect(30, 0, 10, 14))
        space(hallId, firstFloorId, "Hall", .hall, rect(16, 14, 24, 4))
        space(halfBathId, firstFloorId, "Half Bath", .halfBath, rect(0, 18, 8, 12))
        space(laundryId, firstFloorId, "Laundry", .laundry, rect(8, 18, 8, 12))
        // 2nd floor.
        space(primaryId, secondFloorId, "Primary Bedroom", .bedroom, rect(0, 0, 18, 16))
        space(bedroom2Id, secondFloorId, "Bedroom 2", .bedroom, rect(22, 0, 18, 16))
        space(hall2Id, secondFloorId, "Hall", .hall, rect(18, 0, 4, 30))
        space(bathId, secondFloorId, "Bathroom", .bathroom, rect(0, 16, 18, 14))
        // Basement.
        space(utilityId, basementId, "Utility", .utility, rect(0, 0, 14, 20))
        space(storageId, basementId, "Storage", .storage, rect(14, 0, 26, 20))
        // Outside.
        space(id(45), outsideId, "House", .footprint, rect(0, 0, 40, 30), exterior: true, source: .autoseed)
        space(id(46), outsideId, "Front Yard", .frontYard, rect(-10, 30, 60, 25), exterior: true, source: .autoseed, color: "#CFE8C4")
        space(id(47), outsideId, "Backyard", .backyard, rect(-10, -30, 60, 30), exterior: true, source: .autoseed, color: "#CFE8C4")
        space(id(48), outsideId, "Garden Bed", .gardenBed, rect(2, -12, 12, 6), exterior: true, source: .manual, color: "#E6D3B3")

        s.openings[frontDoorOpeningId] = Opening(id: frontDoorOpeningId, propertyId: pid, levelId: firstFloorId, spaceId: hallId,
                                                 kind: .door, segment: Segment(Vec2(26 * ft, 18 * ft), Vec2(29 * ft, 18 * ft)),
                                                 heightIn: 80, swing: .leftIn, isExteriorDoor: true, source: .manual, createdAt: t, updatedAt: t)
        s.openings[id(73)] = Opening(id: id(73), propertyId: pid, levelId: firstFloorId, spaceId: kitchenId, kind: .window,
                                     segment: Segment(Vec2(20 * ft, 0), Vec2(24 * ft, 0)), heightIn: 48, sillIn: 36, createdAt: t, updatedAt: t)

        s.people[mattId] = Person(id: mattId, propertyId: pid, name: "Matt", colorHex: "#2F6FDE", sortOrder: 0, createdAt: t, updatedAt: t)
        s.people[alexId] = Person(id: alexId, propertyId: pid, name: "Alex", colorHex: "#D9480F", sortOrder: 1, createdAt: t, updatedAt: t)

        s.measurements[fridgeOpeningId] = HomeMeasurement(id: fridgeOpeningId, propertyId: pid, label: "Fridge opening", kind: .opening,
                                                          spaceId: kitchenId, dims: Dims3(width: 36, depth: 30, height: 70), createdAt: t, updatedAt: t)
        s.measurements[frontDoorId] = HomeMeasurement(id: frontDoorId, propertyId: pid, label: "Front door", kind: .door, spaceId: hallId,
                                                      openingId: frontDoorOpeningId, dims: Dims3(width: 36, height: 80), isDeliveryPath: true,
                                                      createdAt: t, updatedAt: t)

        func thing(_ tid: UUID, _ scope: Scope, _ cat: Thing.Category, _ name: String, _ key: String?, dims: Dims3 = .empty, pin: Vec2? = nil,
                   attrs: [String: JSONValue] = [:], ownership: Thing.Ownership = .owned, fit: UUID? = nil, warranty: LocalDate? = nil) {
            s.things[tid] = Thing(id: tid, propertyId: pid, scope: scope, category: cat, name: name, ownership: ownership, templateKey: key,
                                  attributes: attrs, warrantyEnd: warranty, dims: dims, fitMeasurementId: fit, pin: pin, createdAt: t, updatedAt: t)
        }
        thing(fridgeId, .space(kitchenId, level: firstFloorId), .appliance, "Refrigerator", "refrigerator",
              dims: Dims3(width: 35.75, depth: 29, height: 69), pin: Vec2(18 * ft, 2 * ft), fit: fridgeOpeningId, warranty: today.adding(days: 40))
        thing(plannedFridgeId, .space(kitchenId, level: firstFloorId), .appliance, "New fridge (planned)", "refrigerator",
              dims: Dims3(width: 36, depth: 31, height: 70), ownership: .planned, fit: fridgeOpeningId)
        thing(furnaceId, .space(utilityId, level: basementId), .system, "Furnace", "hvac_furnace", pin: Vec2(4 * ft, 4 * ft),
              attrs: ["filterSize": "16x25x1", "merv": 11, "fuel": "gas"])
        thing(tvId, .space(livingId, level: firstFloorId), .electronic, "TV", "tv", dims: Dims3(width: 57, depth: 3, height: 33),
              pin: Vec2(8 * ft, 1 * ft), attrs: ["screenSize": 65, "mount": "wall"])
        thing(sofaId, .space(livingId, level: firstFloorId), .furniture, "Sofa", "sofa", dims: Dims3(width: 84, depth: 38, height: 34), pin: Vec2(8 * ft, 12 * ft))
        thing(detectorId, .level(secondFloorId), .fixture, "Smoke detectors", "smoke_detector", attrs: ["batteryType": "9V"])

        func chore(_ cid: UUID, _ scope: Scope, _ title: String, rule: RepeatRule?, start: LocalDate, due: LocalDate?,
                   minutes: Int? = nil, assignee: UUID? = nil, thing: UUID? = nil, remind: Bool = true) {
            s.chores[cid] = Chore(id: cid, propertyId: pid, scope: scope, title: title, assigneeId: assignee, repeatRule: rule, startOn: start,
                                  nextDueOn: due, dueMinutes: minutes, remindEnabled: remind, linkedThingId: thing, createdAt: t, updatedAt: t)
        }
        chore(dishesId, .space(kitchenId, level: firstFloorId), "Do the dishes", rule: .daily, start: today.adding(days: -30), due: today,
              minutes: 20 * 60, assignee: alexId)
        let tue = today.adding(days: (3 - today.weekday + 7) % 7)
        chore(trashId, .property, "Take out the trash", rule: .weekly([3, 6]), start: today.adding(days: -60), due: tue, minutes: 19 * 60, assignee: mattId)
        chore(filterId, .space(utilityId, level: basementId), "Change furnace filter", rule: .everyNDays(90), start: today.adding(days: -100),
              due: today.adding(days: -3), assignee: mattId, thing: furnaceId)
        chore(batteryId, .level(secondFloorId), "Replace detector batteries", rule: .monthly(day: 1, every: 12), start: LocalDate(2026, 11, 1),
              due: LocalDate(2026, 11, 1), thing: detectorId)
        chore(gutterId, .property, "Clean the gutters", rule: nil, start: today.adding(days: 5), due: today.adding(days: 5), remind: false)

        func project(_ prid: UUID, _ scope: Scope, _ title: String, _ status: Project.Status, est: Int64?, actual: Int64? = nil,
                     completed: LocalDate? = nil) {
            s.projects[prid] = Project(id: prid, propertyId: pid, scope: scope, title: title, status: status,
                                       estCost: est.map { Money(cents: $0) }, actualCost: actual.map { Money(cents: $0) },
                                       startedOn: status == .inProgress ? today.adding(days: -10) : nil, completedOn: completed,
                                       createdAt: t, updatedAt: t)
        }
        project(paintId, .space(kitchenId, level: firstFloorId), "Repaint kitchen", .planned, est: 1_200_00)
        project(deckId, .property, "Build a deck", .idea, est: 8_000_00)
        project(bathRemodelId, .space(bathId, level: secondFloorId), "Bathroom remodel", .done, est: 11_000_00, completed: LocalDate(2026, 3, 14))
        project(fridgeProjectId, .space(kitchenId, level: firstFloorId), "Replace fridge", .inProgress, est: 2_400_00)
        for (n, (label, cents, kind)) in [("Tile", 3_400_00, CostLineItem.Kind.material), ("Plumber", 6_200_00, .labor),
                                          ("Permit", 250_00, .permit), ("Vanity", 2_250_00, .material)].enumerated() {
            let li = CostLineItem(id: id(110 + n), propertyId: pid, projectId: bathRemodelId, label: label, amount: Money(cents: Int64(cents)),
                                  kind: kind, createdAt: t, updatedAt: t)
            s.lineItems[li.id] = li
        }

        s.spots[shelfId] = StorageSpot(id: shelfId, propertyId: pid, spaceId: storageId, name: "Shelf 2", pin: Vec2(30 * ft, 4 * ft), createdAt: t, updatedAt: t)
        s.spots[winterBinId] = StorageSpot(id: winterBinId, propertyId: pid, spaceId: storageId, parentSpotId: shelfId, name: "Bin Winter – Matt",
                                           ownerId: mattId, createdAt: t, updatedAt: t)
        func item(_ iid: UUID, _ kind: InventoryItem.Kind, _ name: String, scope: Scope, spot: UUID? = nil, qty: Double = 1, unit: String? = nil,
                  owner: UUID? = nil, season: Season? = nil, rotation: Bool? = nil, expires: LocalDate? = nil, low: Double? = nil,
                  thing: UUID? = nil, category: String? = nil) {
            s.inventory[iid] = InventoryLogic.applyLowThreshold(InventoryItem(
                id: iid, propertyId: pid, kind: kind, name: name, category: category, ownerId: owner, scope: scope, storageSpotId: spot,
                quantity: qty, unit: unit, season: season, inRotation: rotation, expiresOn: expires, lowThreshold: low,
                linkedThingId: thing, createdAt: t, updatedAt: t))
        }
        let storageScope = Scope.space(storageId, level: basementId)
        item(id(120), .clothing, "Winter coat", scope: storageScope, spot: winterBinId, owner: mattId, season: .winter, rotation: false, category: "coat")
        item(id(121), .clothing, "Snow boots", scope: storageScope, spot: winterBinId, owner: mattId, season: .winter, rotation: false, category: "boots")
        item(id(122), .clothing, "Swim trunks", scope: .space(primaryId, level: secondFloorId), owner: mattId, season: .summer, rotation: true, category: "swim")
        item(id(123), .stored, "Furnace filter 16x25x1 MERV 11", scope: storageScope, spot: shelfId, qty: 1, unit: "ea", low: 1, thing: furnaceId)
        item(id(124), .pantry, "Canned tomatoes", scope: .space(kitchenId, level: firstFloorId), qty: 4, unit: "can", expires: today.adding(days: 2), category: "canned")
        item(id(125), .pantry, "Olive oil", scope: .space(kitchenId, level: firstFloorId), qty: 0, unit: "bottle", low: 0)
        return s
    }
}

/// One-stop container of every in-memory service over a single store. Use in previews:
/// `let home = InMemoryHome.sample()` then pass `home.plan`, `home.chores`, … to views.
public struct InMemoryHome: Sendable {
    public let store: InMemoryStore
    public let plan: InMemoryPlanRepository
    public let chores: InMemoryChoreRepository
    public let projects: InMemoryProjectRepository
    public let things: InMemoryThingRepository
    public let inventory: InMemoryInventoryRepository
    public let measurements: InMemoryMeasurementRepository
    public let people: InMemoryPeopleRepository
    public let attachments: InMemoryAttachmentRepository
    public let settings: InMemorySettingsRepository
    public let recentlyDeleted: InMemoryRecentlyDeletedRepository
    public let search: InMemorySearchService
    public let rollups: InMemoryRollupService
    public let lensStats: InMemoryLensStatsService
    public let export: InMemoryExportService
    public let diagnostics: InMemoryDiagnosticsService
    public let reminders: InMemoryReminderScheduler
    public let calendar: InMemoryCalendarSync

    public init(store: InMemoryStore) {
        self.store = store
        plan = .init(store: store); chores = .init(store: store); projects = .init(store: store); things = .init(store: store)
        inventory = .init(store: store); measurements = .init(store: store); people = .init(store: store)
        attachments = .init(store: store); settings = .init(store: store); recentlyDeleted = .init(store: store)
        search = .init(store: store); rollups = .init(store: store); lensStats = .init(store: store); export = .init(store: store)
        diagnostics = .init(store: store); reminders = InMemoryReminderScheduler(store: store); calendar = .init(store: store)
    }

    /// Empty store (onboarding previews).
    public static func empty(clock: HomeClock = SystemClock()) -> InMemoryHome { InMemoryHome(store: InMemoryStore(clock: clock)) }

    /// Sample house relative to the clock's today.
    public static func sample(clock: HomeClock = SystemClock()) -> InMemoryHome {
        InMemoryHome(store: InMemoryStore(SampleHome.snapshot(today: clock.today, now: clock.now), clock: clock))
    }
}

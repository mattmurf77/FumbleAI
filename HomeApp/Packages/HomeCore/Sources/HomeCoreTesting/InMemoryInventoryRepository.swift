import Foundation
import HomeCore
import PlanKit

public struct InMemoryInventoryRepository: InventoryRepository {
    public let store: InMemoryStore
    public init(store: InMemoryStore) { self.store = store }

    static func filter(_ s: InMemorySnapshot, _ q: InventoryQuery) -> [InventoryItem] {
        let subtree = q.spotId.map { Set(InventoryLogic.subtree(of: $0, in: Array(s.spots.values))) }
        return s.liveInventory.filter { i in
            i.propertyId == q.propertyId && scopeMatches(i.scope, scope: q.scope, levelId: q.levelId)
            && (subtree == nil || (i.storageSpotId.map { subtree!.contains($0) } ?? false))
            && (q.kind == nil || i.kind == q.kind) && (q.ownerId == nil || i.ownerId == q.ownerId)
            && (!q.lowOnly || i.isLow)
        }
    }

    /// Scope of the room a spot lives in.
    static func scope(ofSpot id: UUID, _ s: InMemorySnapshot) -> Scope? {
        guard let spot = s.spots[id], let space = s.spaces[spot.spaceId] else { return nil }
        return .space(space.id, level: space.levelId)
    }

    public func item(_ id: UUID) async throws -> InventoryItem? { store.read { $0.inventory[id].flatMap { $0.deletedAt == nil ? $0 : nil } } }
    public func items(_ query: InventoryQuery) async throws -> [InventoryItem] { store.read { Self.filter($0, query) } }
    public func observeItems(_ query: InventoryQuery) -> AsyncStream<[InventoryItem]> { store.observe { Self.filter($0, query) } }

    public func create(_ draft: InventoryDraft) async throws -> InventoryItem {
        let spotScope = draft.storageSpotId.flatMap { id in store.read { Self.scope(ofSpot: id, $0) } }
        if draft.storageSpotId != nil && spotScope == nil { throw notFound(.storageSpot, draft.storageSpotId!) }
        let item = InventoryLogic.make(from: draft, now: store.now, spotScope: spotScope)
        store.write(events: [.created(.inventory(item.id))]) { $0.inventory[item.id] = item }
        return item
    }

    public func update(_ item: InventoryItem) async throws {
        var i = InventoryLogic.applyLowThreshold(item)
        i.updatedAt = store.now
        try store.write(events: [.updated(.inventory(i.id))]) { s in
            guard s.inventory[i.id] != nil else { throw notFound(.inventoryItem, i.id) }
            if let sid = i.storageSpotId, let sc = Self.scope(ofSpot: sid, s) { i.scope = sc }
            s.inventory[i.id] = i
        }
    }

    public func delete(_ id: UUID) async throws {
        try store.write(events: [.deleted(.inventory(id))]) { s in
            guard var i = s.inventory[id] else { throw notFound(.inventoryItem, id) }
            i.deletedAt = store.now; i.updatedAt = store.now
            s.inventory[id] = i
        }
    }

    public func move(_ ids: [UUID], to spot: UUID?) async throws {
        try store.write(events: ids.map { .updated(.inventory($0)) }) { s in
            let target = spot.flatMap { Self.scope(ofSpot: $0, s) }
            if spot != nil && target == nil { throw notFound(.storageSpot, spot!) }
            for id in ids {
                guard var i = s.inventory[id] else { continue }
                i.storageSpotId = spot
                if let target { i.scope = target }
                i.updatedAt = store.now
                s.inventory[id] = i
            }
        }
    }

    public func adjustQuantity(_ id: UUID, by delta: Double) async throws {
        try store.write(events: [.updated(.inventory(id))]) { s in
            guard var i = s.inventory[id] else { throw notFound(.inventoryItem, id) }
            i.quantity = max(0, i.quantity + delta)
            i = InventoryLogic.applyLowThreshold(i)
            i.updatedAt = store.now
            s.inventory[id] = i
        }
    }

    // MARK: Spots

    public func spot(_ id: UUID) async throws -> StorageSpot? { store.read { $0.spots[id].flatMap { $0.deletedAt == nil ? $0 : nil } } }
    public func spots(space: UUID) async throws -> [StorageSpot] {
        store.read { $0.liveSpots.filter { $0.spaceId == space }.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) } }
    }

    public func saveSpot(_ spot: StorageSpot) async throws {
        var sp = spot; sp.updatedAt = store.now
        try store.write(events: [.recordsChanged([RecordRef(.storageSpot, sp.id)])]) { s in
            if sp.parentSpotId == sp.id { throw RepositoryError.cycle }
            if let pid = sp.parentSpotId, let parent = s.spots[pid], parent.spaceId != sp.spaceId { throw RepositoryError.cycle }
            s.spots[sp.id] = sp
        }
    }

    public func deleteSpot(_ id: UUID, moveItemsTo: UUID?) async throws {
        try store.write(events: [.recordsChanged([RecordRef(.storageSpot, id)])]) { s in
            guard s.spots[id] != nil else { throw notFound(.storageSpot, id) }
            let sub = Set(InventoryLogic.subtree(of: id, in: Array(s.spots.values)))
            for sid in sub { if var x = s.spots[sid] { x.deletedAt = store.now; x.updatedAt = store.now; s.spots[sid] = x } }
            for (k, var i) in s.inventory where i.storageSpotId.map({ sub.contains($0) }) ?? false {
                i.storageSpotId = moveItemsTo
                if let t = moveItemsTo.flatMap({ Self.scope(ofSpot: $0, s) }) { i.scope = t }
                i.updatedAt = store.now
                s.inventory[k] = i
            }
        }
    }

    public func reparentSpot(_ id: UUID, to parent: UUID?) async throws {
        try store.write(events: [.recordsChanged([RecordRef(.storageSpot, id)])]) { s in
            guard InventoryLogic.canReparent(id, to: parent, in: Array(s.spots.values)) else { throw RepositoryError.cycle }
            guard var sp = s.spots[id] else { throw notFound(.storageSpot, id) }
            sp.parentSpotId = parent; sp.updatedAt = store.now
            s.spots[id] = sp
        }
    }

    public func observeSpotTree(space: UUID) -> AsyncStream<[SpotNode]> {
        store.observe { s in InventoryLogic.tree(space: space, spots: Array(s.spots.values), items: Array(s.inventory.values)) }
    }

    // MARK: Queries

    static func location(_ i: InventoryItem, _ s: InMemorySnapshot) -> ItemLocation {
        ItemLocation(itemId: i.id, name: i.name, owner: s.personName(i.ownerId), room: s.spaceName(i.scope.spaceId),
                     floor: s.levelName(i.scope.levelId), spotPath: s.spotPath(i.storageSpotId),
                     levelId: i.scope.levelId, spaceId: i.scope.spaceId, spotId: i.storageSpotId)
    }

    public func locations(of ids: [UUID]) async throws -> [ItemLocation] {
        store.read { s in ids.compactMap { s.inventory[$0] }.filter { $0.deletedAt == nil }.map { Self.location($0, s) } }
    }

    public func observeSeasonalSwap(property: UUID, on date: LocalDate) -> AsyncStream<SeasonalSwap> {
        store.observe { s in
            let upcoming = Season.upcoming(on: date, latitude: s.properties[property]?.latitude)
            let clothing = s.liveInventory.filter { $0.propertyId == property && $0.kind == .clothing }
            func line(_ i: InventoryItem) -> SwapLine {
                SwapLine(itemId: i.id, name: i.name, category: i.category, owner: s.personName(i.ownerId),
                         room: s.spaceName(i.scope.spaceId), spotPath: s.spotPath(i.storageSpotId))
            }
            let order: (SwapLine, SwapLine) -> Bool = {
                ($0.owner ?? "", $0.room ?? "", $0.spotPath ?? "", $0.name) < ($1.owner ?? "", $1.room ?? "", $1.spotPath ?? "", $1.name)
            }
            return SeasonalSwap(upcoming: upcoming,
                                getOut: clothing.filter { $0.season == upcoming && $0.inRotation == false }.map(line).sorted(by: order),
                                putAway: clothing.filter { $0.season == upcoming.opposite && $0.inRotation == true }.map(line).sorted(by: order))
        }
    }

    public func applySwap(itemIds: [UUID], inRotation: Bool) async throws {
        store.write(events: itemIds.map { .updated(.inventory($0)) }) { s in
            for id in itemIds { if var i = s.inventory[id] { i.inRotation = inRotation; i.updatedAt = store.now; s.inventory[id] = i } }
        }
    }

    static let replacementTemplates: Set<String> = ["hvac_furnace", "hvac_filter", "water_filter", "light_fixture", "smoke_detector", "fridge_water_filter"]

    public func observeShoppingList(property: UUID, on date: LocalDate) -> AsyncStream<[ShoppingLine]> {
        store.observe { s in
            var lines = s.liveInventory.filter { $0.propertyId == property && $0.isLow }
                .map { ShoppingLine(reason: .low, ref: .inventory($0.id), label: $0.name, quantity: $0.quantity, unit: $0.unit) }
            let horizon = date.adding(days: 14)
            var seen = Set<UUID>()
            for c in s.liveChores where c.propertyId == property && c.closedAt == nil {
                guard let tid = c.linkedThingId, let t = s.things[tid], t.deletedAt == nil, !seen.contains(tid),
                      let due = c.nextDueOn, due <= horizon, let key = t.templateKey, Self.replacementTemplates.contains(key) else { continue }
                let hasSpare = s.liveInventory.contains { $0.linkedThingId == tid && $0.quantity > 0 }
                guard !hasSpare else { continue }
                seen.insert(tid)
                let detail = t.attributes["filterSize"]?.displayText ?? t.attributes["bulbBase"]?.displayText
                lines.append(ShoppingLine(reason: .replacementDue, ref: .thing(tid), label: t.name + (detail.map { " – \($0)" } ?? "")))
            }
            return lines
        }
    }
}

// MARK: - Recently Deleted

public struct InMemoryRecentlyDeletedRepository: RecentlyDeletedRepository {
    public let store: InMemoryStore
    public init(store: InMemoryStore) { self.store = store }

    static func entries(_ s: InMemorySnapshot, property: UUID) -> [DeletedEntry] {
        var out: [DeletedEntry] = []
        func add(_ type: RecordType, _ id: UUID, _ title: String, _ kind: String, _ loc: String?, _ at: Date?, _ pid: UUID) {
            guard let at, pid == property else { return }
            out.append(DeletedEntry(ref: RecordRef(type, id), title: title, kindLabel: kind, originalLocation: loc, deletedAt: at))
        }
        for l in s.levels.values { add(.level, l.id, l.name, "Floor", nil, l.deletedAt, l.propertyId) }
        for x in s.spaces.values { add(.space, x.id, x.name, "Room", s.levelName(x.levelId), x.deletedAt, x.propertyId) }
        for x in s.spots.values { add(.storageSpot, x.id, x.name, "Storage spot", s.spaceName(x.spaceId), x.deletedAt, x.propertyId) }
        for x in s.chores.values { add(.chore, x.id, x.title, "To-Do", s.locationText(x.scope), x.deletedAt, x.propertyId) }
        for x in s.projects.values { add(.project, x.id, x.title, "Project", s.locationText(x.scope), x.deletedAt, x.propertyId) }
        for x in s.things.values { add(.thing, x.id, x.name, "Thing", s.locationText(x.scope), x.deletedAt, x.propertyId) }
        for x in s.inventory.values { add(.inventoryItem, x.id, x.name, "Item", s.locationText(x.scope), x.deletedAt, x.propertyId) }
        for x in s.measurements.values { add(.measurement, x.id, x.label, "Measurement", s.spaceName(x.spaceId), x.deletedAt, x.propertyId) }
        for x in s.people.values { add(.person, x.id, x.name, "Person", nil, x.deletedAt, x.propertyId) }
        return out.sorted { $0.deletedAt > $1.deletedAt }
    }

    public func deleted(property: UUID) async throws -> [DeletedEntry] { store.read { Self.entries($0, property: property) } }
    public func observeDeleted(property: UUID) -> AsyncStream<[DeletedEntry]> { store.observe { Self.entries($0, property: property) } }

    public func restore(_ ref: RecordRef) async throws {
        try store.write(events: [.recordsChanged([ref])]) { s in
            let now = store.now
            switch ref.type {
            case .level: s.levels[ref.id]?.deletedAt = nil
            case .space: s.spaces[ref.id]?.deletedAt = nil
            case .storageSpot:
                s.spots[ref.id]?.deletedAt = nil
                if let p = s.spots[ref.id]?.parentSpotId, s.spots[p]?.deletedAt != nil { s.spots[ref.id]?.parentSpotId = nil }
            case .chore: s.chores[ref.id]?.deletedAt = nil
            case .project: s.projects[ref.id]?.deletedAt = nil
            case .thing: s.things[ref.id]?.deletedAt = nil
            case .inventoryItem: s.inventory[ref.id]?.deletedAt = nil
            case .measurement: s.measurements[ref.id]?.deletedAt = nil
            case .person: s.people[ref.id]?.deletedAt = nil
            case .opening: s.openings[ref.id]?.deletedAt = nil
            case .costLineItem: s.lineItems[ref.id]?.deletedAt = nil
            case .attachment: s.attachments[ref.id]?.deletedAt = nil
            default: throw RepositoryError.invalid("Cannot restore \(ref.type.rawValue)")
            }
            // FR-SES-64: an item whose room is still deleted goes to its floor (or whole house).
            func fix(_ scope: Scope) -> Scope {
                switch scope {
                case .space(let sp, let l) where s.spaces[sp]?.deletedAt != nil:
                    return s.levels[l]?.deletedAt == nil ? .level(l) : .property
                case .level(let l) where s.levels[l]?.deletedAt != nil: return .property
                default: return scope
                }
            }
            if var c = s.chores[ref.id], ref.type == .chore { c.scope = fix(c.scope); c.updatedAt = now; s.chores[ref.id] = c }
            if var p = s.projects[ref.id], ref.type == .project { p.scope = fix(p.scope); p.updatedAt = now; s.projects[ref.id] = p }
            if var t = s.things[ref.id], ref.type == .thing { t.scope = fix(t.scope); t.updatedAt = now; s.things[ref.id] = t }
            if var i = s.inventory[ref.id], ref.type == .inventoryItem {
                let f = fix(i.scope); if f != i.scope { i.storageSpotId = nil }; i.scope = f; i.updatedAt = now; s.inventory[ref.id] = i
            }
        }
    }

    public func purge(_ ref: RecordRef) async throws {
        store.write(events: [.recordsChanged([ref])]) { s in
            switch ref.type {
            case .level: s.levels[ref.id] = nil
            case .space: s.spaces[ref.id] = nil
            case .storageSpot: s.spots[ref.id] = nil
            case .chore: s.chores[ref.id] = nil
            case .project: s.projects[ref.id] = nil
            case .thing: s.things[ref.id] = nil
            case .inventoryItem: s.inventory[ref.id] = nil
            case .measurement: s.measurements[ref.id] = nil
            case .person: s.people[ref.id] = nil
            case .opening: s.openings[ref.id] = nil
            case .costLineItem: s.lineItems[ref.id] = nil
            case .attachment: s.attachments[ref.id] = nil
            case .choreCompletion: s.completions[ref.id] = nil
            case .choreCalendarLink: s.calendarLinks[ref.id] = nil
            case .property: s.properties[ref.id] = nil
            }
        }
    }

    public func purgeExpired(before cutoff: Date) async throws -> Int {
        let refs = store.read { s -> [RecordRef] in
            s.liveProperties.flatMap { Self.entries(s, property: $0.id) }.filter { $0.deletedAt < cutoff }.map(\.ref)
        }
        for r in refs { try await purge(r) }
        return refs.count
    }
}

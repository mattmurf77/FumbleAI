import Foundation
import GRDB
import HomeCore
import PlanKit

/// SQL for the shared scope filter (`scopeMatches`): exact scope, and/or everything on a level.
func scopeFilter(_ scope: Scope?, levelId: UUID?) -> (String, [String]) {
    var parts: [String] = [], args: [String] = []
    if let scope {
        switch scope {
        case .space(let s, let l): parts.append("scope = 'space' AND space_id = ? AND level_id = ?"); args += [s.db, l.db]
        case .level(let l): parts.append("scope = 'level' AND level_id = ?"); args.append(l.db)
        case .property: parts.append("scope = 'property'")
        }
    }
    if let levelId { parts.append("level_id = ?"); args.append(levelId.db) }
    return (parts.isEmpty ? "1" : parts.map { "(\($0))" }.joined(separator: " AND "), args)
}

// MARK: - Chores

/// GRDB `ChoreRepository` (LLD `ChoreServicing`, §9). Business rules come from `ChoreLogic`.
public struct ChoreStore: ChoreRepository {
    public let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    static let farFuture = LocalDate(9999, 12, 31)
    static func sort(_ cs: [Chore]) -> [Chore] {
        cs.sorted { ($0.nextDueOn ?? farFuture, $0.title) < ($1.nextDueOn ?? farFuture, $1.title) }
    }

    static func query(_ d: Database, _ q: ChoreQuery) throws -> [Chore] {
        var (sql, args) = scopeFilter(q.scope, levelId: q.levelId)
        sql += " AND property_id = ?"; args.append(q.propertyId.db)
        if !q.includeClosed { sql += " AND closed_at IS NULL" }
        if !q.includePaused { sql += " AND is_paused = 0" }
        if let t = q.linkedThingId { sql += " AND linked_thing_id = ?"; args.append(t.db) }
        if let a = q.assigneeId { sql += " AND assignee_id = ?"; args.append(a.db) }
        return sort(try Chore.fetchAll(d, where: sql, StatementArguments(args)))
    }

    public func chore(_ id: UUID) async throws -> Chore? { try await db.read { try Chore.fetchOne($0, id: id, includeDeleted: false) } }
    public func chores(_ query: ChoreQuery) async throws -> [Chore] { try await db.read { try Self.query($0, query) } }
    public func observeChores(_ query: ChoreQuery) -> AsyncStream<[Chore]> { db.observe { try Self.query($0, query) } }

    static func completions(_ d: Database, chore: UUID) throws -> [ChoreCompletion] {
        try ChoreCompletion.fetchAll(d, where: "chore_id = ?", [chore.db]).sorted { $0.doneAt > $1.doneAt }
    }
    public func completions(chore: UUID) async throws -> [ChoreCompletion] { try await db.read { try Self.completions($0, chore: chore) } }

    public func create(_ draft: ChoreDraft) async throws -> Chore {
        let c = ChoreLogic.make(from: draft, now: db.clock.now, engine: db.engine)
        return try await db.write { tx in
            let saved = try tx.save(c)
            tx.emit(.created(.chore(c.id)))
            return saved
        }
    }

    public func update(_ chore: Chore) async throws {
        try await db.write { tx in
            var c = chore
            let old = try tx.require(Chore.self, c.id, includeDeleted: true)
            if (old.repeatRule != c.repeatRule || old.startOn != c.startOn) && c.closedAt == nil && old.nextDueOn == c.nextDueOn {
                c = ChoreLogic.recomputeNextDue(c, completions: try Self.completions(tx.db, chore: c.id), engine: tx.engine)
            }
            try tx.save(c)
            tx.emit(.updated(.chore(c.id)))
        }
    }

    private func act(_ id: UUID, _ outcome: ChoreCompletion.Outcome, by: UUID?, at: Date) async throws -> ChoreCompletion {
        try await db.write { tx in
            let c = try tx.require(Chore.self, id)
            let (updated, completion) = ChoreLogic.act(on: c, outcome: outcome, by: by, at: at, calendar: tx.calendar, engine: tx.engine)
            try tx.save(updated)
            let saved = try tx.save(completion, stamp: false)
            tx.emit(.choreCompleted(id)); tx.emit(.updated(.chore(id)))
            return saved
        }
    }

    public func complete(_ id: UUID, by person: UUID?, at: Date) async throws -> ChoreCompletion { try await act(id, .done, by: person, at: at) }
    public func skip(_ id: UUID, at: Date) async throws { _ = try await act(id, .skipped, by: nil, at: at) }

    public func reschedule(_ id: UUID, to: LocalDate) async throws { try await mutate(id) { $0.nextDueOn = to; $0.closedAt = nil } }
    public func setPaused(_ id: UUID, _ paused: Bool) async throws { try await mutate(id) { $0.isPaused = paused } }

    public func turnIntoProject(_ id: UUID) async throws -> Project {
        try await db.write { tx in
            let c = try tx.require(Chore.self, id, includeDeleted: true)
            let p = ProjectLogic.make(from: ChoreLogic.projectDraft(from: c), now: tx.now, today: tx.today)
            let saved = try tx.save(p)
            tx.emit(.created(.project(p.id)))
            return saved
        }
    }

    public func delete(_ id: UUID) async throws {
        try await db.write { tx in
            try tx.softDelete(try tx.require(Chore.self, id, includeDeleted: true))
            tx.emit(.deleted(.chore(id)))
        }
    }

    public func calendarLink(chore: UUID) async throws -> ChoreCalendarLink? {
        try await db.read { try ChoreCalendarLink.fetchOne($0, id: chore, includeDeleted: false) }
    }

    public func saveCalendarLink(_ link: ChoreCalendarLink) async throws {
        try await db.write { tx in
            var l = link
            l.deletedAt = nil
            if let old = try tx.get(ChoreCalendarLink.self, l.id, includeDeleted: true) { l.createdAt = old.createdAt }
            try tx.save(l)
            tx.emit(.recordsChanged([RecordRef(.choreCalendarLink, l.id)]))
        }
    }

    public func deleteCalendarLink(chore: UUID) async throws {
        try await db.write { tx in
            guard let l = try tx.get(ChoreCalendarLink.self, chore) else { return }
            try tx.softDelete(l)
            tx.emit(.recordsChanged([RecordRef(.choreCalendarLink, chore)]))
        }
    }

    private func mutate(_ id: UUID, _ f: @escaping @Sendable (inout Chore) -> Void) async throws {
        try await db.write { tx in
            var c = try tx.require(Chore.self, id)
            f(&c)
            try tx.save(c)
            tx.emit(.updated(.chore(id)))
        }
    }
}

// MARK: - Projects

/// GRDB `ProjectRepository` (LLD `ProjectServicing`, §8). Status rules come from `ProjectLogic`.
public struct ProjectStore: ProjectRepository {
    public let db: AppDatabase
    public let files: AttachmentFileStore
    public init(_ db: AppDatabase, files: AttachmentFileStore) { self.db = db; self.files = files }

    static func query(_ d: Database, _ q: ProjectQuery) throws -> [Project] {
        var (sql, args) = scopeFilter(q.scope, levelId: q.levelId)
        sql += " AND property_id = ?"; args.append(q.propertyId.db)
        if let st = q.statuses {
            let known = st.filter { $0 != .unknown }
            if known.isEmpty { return [] }
            sql += " AND status IN (\(known.map { "'\($0.rawValue)'" }.sorted().joined(separator: ",")))"
        }
        return try Project.fetchAll(d, where: sql, StatementArguments(args)).sorted { $0.title < $1.title }
    }

    public func project(_ id: UUID) async throws -> Project? { try await db.read { try Project.fetchOne($0, id: id, includeDeleted: false) } }
    public func projects(_ query: ProjectQuery) async throws -> [Project] { try await db.read { try Self.query($0, query) } }
    public func observeProjects(_ query: ProjectQuery) -> AsyncStream<[Project]> { db.observe { try Self.query($0, query) } }

    public func create(_ draft: ProjectDraft) async throws -> Project {
        let p = ProjectLogic.make(from: draft, now: db.clock.now, today: db.clock.today)
        return try await db.write { tx in
            let saved = try tx.save(p)
            tx.emit(.created(.project(p.id)))
            return saved
        }
    }

    public func update(_ project: Project) async throws {
        try await db.write { tx in
            var p = project
            _ = try tx.require(Project.self, p.id, includeDeleted: true)
            if p.status == .done && p.completedOn == nil { p.completedOn = tx.today }
            try tx.save(p)
            tx.emit(.updated(.project(p.id)))
        }
    }

    public func setStatus(_ id: UUID, _ status: Project.Status) async throws {
        try await mutate(id) { p, today in p = ProjectLogic.setStatus(p, status, today: today) }
    }

    public func markDone(_ id: UUID, actual: Money?, completedOn: LocalDate, hours: Double?, receipt: AttachmentDraft?) async throws {
        var prepared: Attachment?
        if let receipt {
            let pid = try await db.read { try Project.fetchOne($0, id: id)?.propertyId }
            guard let pid else { throw RepositoryError.notFound(RecordRef(.project, id)) }
            prepared = try AttachmentStore.prepare(receipt, ownerType: .project, ownerId: id, property: pid, files: files, now: db.clock.now)
        }
        let attachment = prepared
        try await db.write { tx in
            var p = try tx.require(Project.self, id)
            p = ProjectLogic.markDone(p, actual: actual, completedOn: completedOn, hours: hours)
            try tx.save(p)
            if let attachment { try AttachmentStore.insert(attachment, in: tx) }
            tx.emit(.updated(.project(id)))
        }
    }

    public func reopen(_ id: UUID) async throws { try await mutate(id) { p, today in p = ProjectLogic.reopen(p, today: today) } }

    public func delete(_ id: UUID) async throws {
        try await db.write { tx in
            try tx.softDelete(try tx.require(Project.self, id, includeDeleted: true))
            tx.emit(.deleted(.project(id)))
        }
    }

    static func lineItems(_ d: Database, project: UUID) throws -> [CostLineItem] {
        try CostLineItem.fetchAll(d, where: "project_id = ?", [project.db]).sorted { ($0.createdAt, $0.id.db) < ($1.createdAt, $1.id.db) }
    }
    public func lineItems(project: UUID) async throws -> [CostLineItem] { try await db.read { try Self.lineItems($0, project: project) } }
    public func observeLineItems(project: UUID) -> AsyncStream<[CostLineItem]> { db.observe { try Self.lineItems($0, project: project) } }

    public func upsertLineItem(_ item: CostLineItem) async throws {
        guard item.amount.cents >= 0 else { throw RepositoryError.invalid("amount must be ≥ 0") }
        try await db.write { tx in
            var i = item
            if let old = try tx.get(CostLineItem.self, i.id, includeDeleted: true) { i.createdAt = old.createdAt }
            try tx.save(i)
            tx.emit(.updated(.project(i.projectId)))
        }
    }

    public func deleteLineItem(_ id: UUID) async throws {
        try await db.write { tx in
            guard let i = try tx.get(CostLineItem.self, id) else { return }
            try tx.softDelete(i)
            tx.emit(.updated(.project(i.projectId)))
        }
    }

    private func mutate(_ id: UUID, _ f: @escaping @Sendable (inout Project, LocalDate) -> Void) async throws {
        try await db.write { tx in
            var p = try tx.require(Project.self, id)
            f(&p, tx.today)
            try tx.save(p)
            tx.emit(.updated(.project(id)))
        }
    }
}

// MARK: - Things

/// GRDB `ThingRepository` (LLD `ThingServicing`, §10). Fit is computed with `FitChecker`, never stored.
public struct ThingStore: ThingRepository {
    public let db: AppDatabase
    public let fitChecker: FitChecker
    public init(_ db: AppDatabase, fitChecker: FitChecker = FitChecker()) { self.db = db; self.fitChecker = fitChecker }

    static func query(_ d: Database, _ q: ThingQuery) throws -> [Thing] {
        var (sql, args) = scopeFilter(q.scope, levelId: q.levelId)
        sql += " AND property_id = ?"; args.append(q.propertyId.db)
        if let c = q.category { sql += " AND category = ?"; args.append(c.rawValue) }
        if let o = q.ownership { sql += " AND ownership = ?"; args.append(o.rawValue) }
        return try Thing.fetchAll(d, where: sql, StatementArguments(args)).sorted { $0.name < $1.name }
    }

    public func thing(_ id: UUID) async throws -> Thing? { try await db.read { try Thing.fetchOne($0, id: id, includeDeleted: false) } }
    public func things(_ query: ThingQuery) async throws -> [Thing] { try await db.read { try Self.query($0, query) } }
    public func observeThings(_ query: ThingQuery) -> AsyncStream<[Thing]> { db.observe { try Self.query($0, query) } }

    public func create(_ d: ThingDraft) async throws -> Thing {
        let now = db.clock.now
        let t = Thing(propertyId: d.propertyId, scope: d.scope, category: d.category, name: d.name, ownership: d.ownership,
                      templateKey: d.templateKey, attributes: d.attributes, brand: d.brand, model: d.model, serial: d.serial,
                      purchaseDate: d.purchaseDate, purchasePrice: d.purchasePrice, warrantyEnd: d.warrantyEnd, dims: d.dims,
                      fitMeasurementId: d.fitMeasurementId, pin: d.pin, notes: d.notes, createdAt: now, updatedAt: now)
        return try await db.write { tx in
            let saved = try tx.save(t)
            tx.emit(.created(.thing(t.id)))
            return saved
        }
    }

    public func update(_ thing: Thing) async throws {
        try await db.write { tx in
            _ = try tx.require(Thing.self, thing.id, includeDeleted: true)
            try tx.save(thing)
            tx.emit(.updated(.thing(thing.id)))
        }
    }

    public func delete(_ id: UUID) async throws {
        try await db.write { tx in
            try tx.softDelete(try tx.require(Thing.self, id, includeDeleted: true))
            tx.emit(.deleted(.thing(id)))
        }
    }

    public func fit(for id: UUID) async throws -> [FitReport] {
        let checker = fitChecker
        return try await db.read { d in
            guard let t = try Thing.fetchOne(d, id: id) else { throw RepositoryError.notFound(RecordRef(.thing, id)) }
            let policy = FitPolicy.default(templateKey: t.templateKey, category: t.category)
            var out: [FitReport] = []
            if let mid = t.fitMeasurementId, let m = try HomeMeasurement.fetchOne(d, id: mid, includeDeleted: false) {
                out.append(FitReport(measurementId: m.id, label: m.label, role: .target, result: checker.check(item: t.dims, into: m.dims, policy: policy)))
            }
            for m in try MeasurementStore.list(d, "property_id = ? AND is_delivery_path = 1", [t.propertyId.db]) {
                out.append(FitReport(measurementId: m.id, label: m.label, role: .deliveryPath, result: checker.passThrough(item: t.dims, door: m.dims)))
            }
            return out
        }
    }
}

// MARK: - Measurements

public struct MeasurementStore: MeasurementRepository {
    public let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    static func list(_ d: Database, _ sql: String, _ args: StatementArguments) throws -> [HomeMeasurement] {
        try HomeMeasurement.fetchAll(d, where: sql, args).sorted { ($0.label, $0.id.db) < ($1.label, $1.id.db) }
    }

    public func measurement(_ id: UUID) async throws -> HomeMeasurement? { try await db.read { try HomeMeasurement.fetchOne($0, id: id, includeDeleted: false) } }
    public func measurements(space: UUID) async throws -> [HomeMeasurement] { try await db.read { try Self.list($0, "space_id = ?", [space.db]) } }
    public func observeMeasurements(space: UUID) -> AsyncStream<[HomeMeasurement]> { db.observe { try Self.list($0, "space_id = ?", [space.db]) } }
    public func measurements(property: UUID) async throws -> [HomeMeasurement] { try await db.read { try Self.list($0, "property_id = ?", [property.db]) } }
    public func deliveryPaths(property: UUID) async throws -> [HomeMeasurement] {
        try await db.read { try Self.list($0, "property_id = ? AND is_delivery_path = 1", [property.db]) }
    }

    static let invalidMessage = "A measurement needs a room or opening and at least one positive dimension"

    public func create(_ i: MeasurementInput) async throws -> HomeMeasurement {
        let now = db.clock.now
        let m = HomeMeasurement(propertyId: i.propertyId, label: i.label, kind: i.kind, spaceId: i.spaceId, openingId: i.openingId,
                                storageSpotId: i.storageSpotId, pin: i.pin, segment: i.segment, dims: i.dims,
                                isDeliveryPath: i.isDeliveryPath, note: i.note, source: i.source, createdAt: now, updatedAt: now)
        guard m.isValid else { throw RepositoryError.invalid(Self.invalidMessage) }
        return try await db.write { tx in
            let saved = try tx.save(m)
            tx.emit(.created(.measurement(m.id)))
            return saved
        }
    }

    public func update(_ measurement: HomeMeasurement) async throws {
        guard measurement.isValid else { throw RepositoryError.invalid(Self.invalidMessage) }
        try await db.write { tx in
            _ = try tx.require(HomeMeasurement.self, measurement.id, includeDeleted: true)
            try tx.save(measurement)
            tx.emit(.updated(.measurement(measurement.id)))
        }
    }

    public func delete(_ id: UUID) async throws {
        try await db.write { tx in
            try tx.softDelete(try tx.require(HomeMeasurement.self, id, includeDeleted: true))
            for var t in try Thing.fetchAll(tx.db, where: "fit_measurement_id = ?", [id.db], includeDeleted: true) {
                t.fitMeasurementId = nil
                try tx.save(t)
            }
            tx.emit(.deleted(.measurement(id)))
        }
    }
}

// MARK: - People

public struct PeopleStore: PeopleRepository {
    public let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    static func list(_ d: Database, property: UUID) throws -> [Person] {
        try Person.fetchAll(d, where: "property_id = ?", [property.db]).sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
    }

    public func people(property: UUID) async throws -> [Person] { try await db.read { try Self.list($0, property: property) } }
    public func observePeople(property: UUID) -> AsyncStream<[Person]> { db.observe { try Self.list($0, property: property) } }

    public func save(_ person: Person) async throws {
        try await db.write { tx in
            try tx.save(person)
            tx.emit(.recordsChanged([RecordRef(.person, person.id)]))
        }
    }

    public func delete(_ id: UUID) async throws {
        try await db.write { tx in
            try tx.softDelete(try tx.require(Person.self, id, includeDeleted: true))
            tx.emit(.recordsChanged([RecordRef(.person, id)]))
        }
    }

    public func reorder(_ ids: [UUID]) async throws {
        try await db.write { tx in
            for (i, id) in ids.enumerated() {
                guard var p = try tx.get(Person.self, id, includeDeleted: true) else { continue }
                p.sortOrder = i
                try tx.save(p)
            }
            tx.emit(.recordsChanged(Set(ids.map { RecordRef(.person, $0) })))
        }
    }
}

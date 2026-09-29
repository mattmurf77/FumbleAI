import Foundation
import HomeCore
import PlanKit

// MARK: - Chores

public struct InMemoryChoreRepository: ChoreRepository {
    public let store: InMemoryStore
    public init(store: InMemoryStore) { self.store = store }

    static func filter(_ s: InMemorySnapshot, _ q: ChoreQuery) -> [Chore] {
        s.liveChores.filter { c in
            c.propertyId == q.propertyId && scopeMatches(c.scope, scope: q.scope, levelId: q.levelId)
            && (q.includeClosed || c.closedAt == nil) && (q.includePaused || !c.isPaused)
            && (q.linkedThingId == nil || c.linkedThingId == q.linkedThingId)
            && (q.assigneeId == nil || c.assigneeId == q.assigneeId)
        }
    }

    public func chore(_ id: UUID) async throws -> Chore? { store.read { $0.chores[id].flatMap { $0.deletedAt == nil ? $0 : nil } } }
    public func chores(_ query: ChoreQuery) async throws -> [Chore] { store.read { Self.filter($0, query) } }
    public func observeChores(_ query: ChoreQuery) -> AsyncStream<[Chore]> { store.observe { Self.filter($0, query) } }
    public func completions(chore: UUID) async throws -> [ChoreCompletion] { store.read { $0.liveCompletions.filter { $0.choreId == chore } } }

    public func create(_ draft: ChoreDraft) async throws -> Chore {
        let c = ChoreLogic.make(from: draft, now: store.now, engine: store.engine)
        store.write(events: [.created(.chore(c.id))]) { $0.chores[c.id] = c }
        return c
    }

    public func update(_ chore: Chore) async throws {
        var c = chore
        c.updatedAt = store.now
        try store.write(events: [.updated(.chore(c.id))]) { s in
            guard let old = s.chores[c.id] else { throw notFound(.chore, c.id) }
            if (old.repeatRule != c.repeatRule || old.startOn != c.startOn) && c.closedAt == nil && old.nextDueOn == c.nextDueOn {
                c = ChoreLogic.recomputeNextDue(c, completions: Array(s.completions.values), engine: store.engine)
            }
            s.chores[c.id] = c
        }
    }

    private func act(_ id: UUID, _ outcome: ChoreCompletion.Outcome, by: UUID?, at: Date) throws -> ChoreCompletion {
        try store.write(events: [.choreCompleted(id), .updated(.chore(id))]) { s in
            guard let c = s.chores[id], c.deletedAt == nil else { throw notFound(.chore, id) }
            let (updated, completion) = ChoreLogic.act(on: c, outcome: outcome, by: by, at: at,
                                                       calendar: store.clock.calendar, engine: store.engine)
            s.chores[id] = updated
            s.completions[completion.id] = completion
            return completion
        }
    }

    public func complete(_ id: UUID, by person: UUID?, at: Date) async throws -> ChoreCompletion { try act(id, .done, by: person, at: at) }
    public func skip(_ id: UUID, at: Date) async throws { _ = try act(id, .skipped, by: nil, at: at) }

    public func reschedule(_ id: UUID, to: LocalDate) async throws {
        try mutate(id) { $0.nextDueOn = to; $0.closedAt = nil }
    }

    public func setPaused(_ id: UUID, _ paused: Bool) async throws { try mutate(id) { $0.isPaused = paused } }

    public func turnIntoProject(_ id: UUID) async throws -> Project {
        guard let c = store.read({ $0.chores[id] }) else { throw notFound(.chore, id) }
        let p = ProjectLogic.make(from: ChoreLogic.projectDraft(from: c), now: store.now, today: store.today)
        store.write(events: [.created(.project(p.id))]) { $0.projects[p.id] = p }
        return p
    }

    public func delete(_ id: UUID) async throws {
        try store.write(events: [.deleted(.chore(id))]) { s in
            guard var c = s.chores[id] else { throw notFound(.chore, id) }
            c.deletedAt = store.now; c.updatedAt = store.now
            s.chores[id] = c
        }
    }

    public func calendarLink(chore: UUID) async throws -> ChoreCalendarLink? {
        store.read { $0.calendarLinks[chore].flatMap { $0.deletedAt == nil ? $0 : nil } }
    }
    public func saveCalendarLink(_ link: ChoreCalendarLink) async throws {
        var l = link; l.updatedAt = store.now; l.deletedAt = nil
        store.write(events: [.recordsChanged([RecordRef(.choreCalendarLink, l.id)])]) { $0.calendarLinks[l.id] = l }
    }
    public func deleteCalendarLink(chore: UUID) async throws {
        store.write(events: [.recordsChanged([RecordRef(.choreCalendarLink, chore)])]) { s in
            if var l = s.calendarLinks[chore] { l.deletedAt = store.now; s.calendarLinks[chore] = l }
        }
    }

    private func mutate(_ id: UUID, _ f: (inout Chore) -> Void) throws {
        try store.write(events: [.updated(.chore(id))]) { s in
            guard var c = s.chores[id], c.deletedAt == nil else { throw notFound(.chore, id) }
            f(&c); c.updatedAt = store.now
            s.chores[id] = c
        }
    }
}

// MARK: - Projects

public struct InMemoryProjectRepository: ProjectRepository {
    public let store: InMemoryStore
    public init(store: InMemoryStore) { self.store = store }

    static func filter(_ s: InMemorySnapshot, _ q: ProjectQuery) -> [Project] {
        s.liveProjects.filter { p in
            p.propertyId == q.propertyId && scopeMatches(p.scope, scope: q.scope, levelId: q.levelId)
            && (q.statuses?.contains(p.status) ?? true)
        }
    }

    public func project(_ id: UUID) async throws -> Project? { store.read { $0.projects[id].flatMap { $0.deletedAt == nil ? $0 : nil } } }
    public func projects(_ query: ProjectQuery) async throws -> [Project] { store.read { Self.filter($0, query) } }
    public func observeProjects(_ query: ProjectQuery) -> AsyncStream<[Project]> { store.observe { Self.filter($0, query) } }

    public func create(_ draft: ProjectDraft) async throws -> Project {
        let p = ProjectLogic.make(from: draft, now: store.now, today: store.today)
        store.write(events: [.created(.project(p.id))]) { $0.projects[p.id] = p }
        return p
    }

    public func update(_ project: Project) async throws {
        var p = project
        p.updatedAt = store.now
        if p.status == .done && p.completedOn == nil { p.completedOn = store.today }
        try store.write(events: [.updated(.project(p.id))]) { s in
            guard s.projects[p.id] != nil else { throw notFound(.project, p.id) }
            s.projects[p.id] = p
        }
    }

    public func setStatus(_ id: UUID, _ status: Project.Status) async throws {
        try mutate(id) { $0 = ProjectLogic.setStatus($0, status, today: store.today) }
    }

    public func markDone(_ id: UUID, actual: Money?, completedOn: LocalDate, hours: Double?, receipt: AttachmentDraft?) async throws {
        try mutate(id) { $0 = ProjectLogic.markDone($0, actual: actual, completedOn: completedOn, hours: hours) }
        if let receipt, let pid = store.read({ $0.projects[id]?.propertyId }) {
            _ = try await InMemoryAttachmentRepository(store: store).add(receipt, ownerType: .project, ownerId: id, property: pid)
        }
    }

    public func reopen(_ id: UUID) async throws { try mutate(id) { $0 = ProjectLogic.reopen($0, today: store.today) } }

    public func delete(_ id: UUID) async throws {
        try store.write(events: [.deleted(.project(id))]) { s in
            guard var p = s.projects[id] else { throw notFound(.project, id) }
            p.deletedAt = store.now; p.updatedAt = store.now
            s.projects[id] = p
        }
    }

    public func lineItems(project: UUID) async throws -> [CostLineItem] { store.read { $0.liveLineItems.filter { $0.projectId == project } } }
    public func observeLineItems(project: UUID) -> AsyncStream<[CostLineItem]> { store.observe { $0.liveLineItems.filter { $0.projectId == project } } }

    public func upsertLineItem(_ item: CostLineItem) async throws {
        guard item.amount.cents >= 0 else { throw RepositoryError.invalid("amount must be ≥ 0") }
        var i = item; i.updatedAt = store.now
        store.write(events: [.updated(.project(i.projectId))]) { $0.lineItems[i.id] = i }
    }

    public func deleteLineItem(_ id: UUID) async throws {
        let pid = store.read { $0.lineItems[id]?.projectId }
        store.write(events: pid.map { [.updated(.project($0))] } ?? []) { s in
            if var i = s.lineItems[id] { i.deletedAt = store.now; i.updatedAt = store.now; s.lineItems[id] = i }
        }
    }

    private func mutate(_ id: UUID, _ f: (inout Project) -> Void) throws {
        try store.write(events: [.updated(.project(id))]) { s in
            guard var p = s.projects[id], p.deletedAt == nil else { throw notFound(.project, id) }
            f(&p); p.updatedAt = store.now
            s.projects[id] = p
        }
    }
}

// MARK: - Things

public struct InMemoryThingRepository: ThingRepository {
    public let store: InMemoryStore
    public let fitChecker: FitChecker
    public init(store: InMemoryStore, fitChecker: FitChecker = FitChecker()) { self.store = store; self.fitChecker = fitChecker }

    static func filter(_ s: InMemorySnapshot, _ q: ThingQuery) -> [Thing] {
        s.liveThings.filter { t in
            t.propertyId == q.propertyId && scopeMatches(t.scope, scope: q.scope, levelId: q.levelId)
            && (q.category == nil || t.category == q.category) && (q.ownership == nil || t.ownership == q.ownership)
        }
    }

    public func thing(_ id: UUID) async throws -> Thing? { store.read { $0.things[id].flatMap { $0.deletedAt == nil ? $0 : nil } } }
    public func things(_ query: ThingQuery) async throws -> [Thing] { store.read { Self.filter($0, query) } }
    public func observeThings(_ query: ThingQuery) -> AsyncStream<[Thing]> { store.observe { Self.filter($0, query) } }

    public func create(_ d: ThingDraft) async throws -> Thing {
        let now = store.now
        let t = Thing(propertyId: d.propertyId, scope: d.scope, category: d.category, name: d.name, ownership: d.ownership,
                      templateKey: d.templateKey, attributes: d.attributes, brand: d.brand, model: d.model, serial: d.serial,
                      purchaseDate: d.purchaseDate, purchasePrice: d.purchasePrice, warrantyEnd: d.warrantyEnd, dims: d.dims,
                      fitMeasurementId: d.fitMeasurementId, pin: d.pin, notes: d.notes, createdAt: now, updatedAt: now)
        store.write(events: [.created(.thing(t.id))]) { $0.things[t.id] = t }
        return t
    }

    public func update(_ thing: Thing) async throws {
        var t = thing; t.updatedAt = store.now
        try store.write(events: [.updated(.thing(t.id))]) { s in
            guard s.things[t.id] != nil else { throw notFound(.thing, t.id) }
            s.things[t.id] = t
        }
    }

    public func delete(_ id: UUID) async throws {
        try store.write(events: [.deleted(.thing(id))]) { s in
            guard var t = s.things[id] else { throw notFound(.thing, id) }
            t.deletedAt = store.now; t.updatedAt = store.now
            s.things[id] = t
        }
    }

    public func fit(for id: UUID) async throws -> [FitReport] {
        try store.read { s in
            guard let t = s.things[id] else { throw notFound(.thing, id) }
            let policy = FitPolicy.default(templateKey: t.templateKey, category: t.category)
            var out: [FitReport] = []
            if let mid = t.fitMeasurementId, let m = s.measurements[mid], m.deletedAt == nil {
                out.append(FitReport(measurementId: m.id, label: m.label, role: .target,
                                     result: fitChecker.check(item: t.dims, into: m.dims, policy: policy)))
            }
            for m in s.liveMeasurements where m.isDeliveryPath && m.propertyId == t.propertyId {
                out.append(FitReport(measurementId: m.id, label: m.label, role: .deliveryPath,
                                     result: fitChecker.passThrough(item: t.dims, door: m.dims)))
            }
            return out
        }
    }
}

// MARK: - Measurements

public struct InMemoryMeasurementRepository: MeasurementRepository {
    public let store: InMemoryStore
    public init(store: InMemoryStore) { self.store = store }

    public func measurement(_ id: UUID) async throws -> HomeMeasurement? { store.read { $0.measurements[id].flatMap { $0.deletedAt == nil ? $0 : nil } } }
    public func measurements(space: UUID) async throws -> [HomeMeasurement] { store.read { $0.liveMeasurements.filter { $0.spaceId == space } } }
    public func observeMeasurements(space: UUID) -> AsyncStream<[HomeMeasurement]> { store.observe { $0.liveMeasurements.filter { $0.spaceId == space } } }
    public func measurements(property: UUID) async throws -> [HomeMeasurement] { store.read { $0.liveMeasurements.filter { $0.propertyId == property } } }
    public func deliveryPaths(property: UUID) async throws -> [HomeMeasurement] {
        store.read { $0.liveMeasurements.filter { $0.propertyId == property && $0.isDeliveryPath } }
    }

    public func create(_ i: MeasurementInput) async throws -> HomeMeasurement {
        let now = store.now
        let m = HomeMeasurement(propertyId: i.propertyId, label: i.label, kind: i.kind, spaceId: i.spaceId, openingId: i.openingId,
                            storageSpotId: i.storageSpotId, pin: i.pin, segment: i.segment, dims: i.dims,
                            isDeliveryPath: i.isDeliveryPath, note: i.note, source: i.source, createdAt: now, updatedAt: now)
        guard m.isValid else { throw RepositoryError.invalid("A measurement needs a room or opening and at least one positive dimension") }
        store.write(events: [.created(.measurement(m.id))]) { $0.measurements[m.id] = m }
        return m
    }

    public func update(_ measurement: HomeMeasurement) async throws {
        guard measurement.isValid else { throw RepositoryError.invalid("A measurement needs a room or opening and at least one positive dimension") }
        var m = measurement; m.updatedAt = store.now
        try store.write(events: [.updated(.measurement(m.id))]) { s in
            guard s.measurements[m.id] != nil else { throw notFound(.measurement, m.id) }
            s.measurements[m.id] = m
        }
    }

    public func delete(_ id: UUID) async throws {
        try store.write(events: [.deleted(.measurement(id))]) { s in
            guard var m = s.measurements[id] else { throw notFound(.measurement, id) }
            m.deletedAt = store.now; m.updatedAt = store.now
            s.measurements[id] = m
            for (k, var t) in s.things where t.fitMeasurementId == id { t.fitMeasurementId = nil; s.things[k] = t }
        }
    }
}

// MARK: - People

public struct InMemoryPeopleRepository: PeopleRepository {
    public let store: InMemoryStore
    public init(store: InMemoryStore) { self.store = store }

    public func people(property: UUID) async throws -> [Person] { store.read { $0.livePeople.filter { $0.propertyId == property } } }
    public func observePeople(property: UUID) -> AsyncStream<[Person]> { store.observe { $0.livePeople.filter { $0.propertyId == property } } }
    public func save(_ person: Person) async throws {
        var p = person; p.updatedAt = store.now
        store.write(events: [.recordsChanged([RecordRef(.person, p.id)])]) { $0.people[p.id] = p }
    }
    public func delete(_ id: UUID) async throws {
        try store.write(events: [.recordsChanged([RecordRef(.person, id)])]) { s in
            guard var p = s.people[id] else { throw notFound(.person, id) }
            p.deletedAt = store.now; p.updatedAt = store.now
            s.people[id] = p
        }
    }
    public func reorder(_ ids: [UUID]) async throws {
        store.write(events: [.recordsChanged(Set(ids.map { RecordRef(.person, $0) }))]) { s in
            for (i, id) in ids.enumerated() { if var p = s.people[id] { p.sortOrder = i; p.updatedAt = store.now; s.people[id] = p } }
        }
    }
}

// MARK: - Attachments

public struct InMemoryAttachmentRepository: AttachmentRepository {
    public let store: InMemoryStore
    public init(store: InMemoryStore) { self.store = store }

    public func attachments(ownerType: Attachment.OwnerType, ownerId: UUID) async throws -> [Attachment] {
        store.read { $0.liveAttachments.filter { $0.ownerType == ownerType && $0.ownerId == ownerId }.sorted { $0.createdAt < $1.createdAt } }
    }

    public func add(_ d: AttachmentDraft, ownerType: Attachment.OwnerType, ownerId: UUID, property: UUID) async throws -> Attachment {
        let size = (try? FileManager.default.attributesOfItem(atPath: d.fileURL.path)[.size] as? Int) ?? 0
        let now = store.now
        let a = Attachment(propertyId: property, ownerType: ownerType, ownerId: ownerId, kind: d.kind, fileExt: d.fileExt,
                           uti: d.uti, byteSize: size, widthPx: d.widthPx, heightPx: d.heightPx,
                           sha256: String(PlannedNotification.stableHash(d.fileURL.absoluteString), radix: 16),
                           caption: d.caption, ocrText: d.ocrText, capturedAt: d.capturedAt, createdAt: now, updatedAt: now)
        store.write(events: [.recordsChanged([RecordRef(.attachment, a.id)])]) { $0.attachments[a.id] = a }
        InMemoryAttachmentRepository.files.set(a.id, d.fileURL)
        return a
    }

    public func delete(_ id: UUID) async throws {
        store.write(events: [.recordsChanged([RecordRef(.attachment, id)])]) { s in
            if var a = s.attachments[id] { a.deletedAt = store.now; s.attachments[id] = a }
        }
    }

    public func fileURL(for attachment: Attachment) async -> URL? { InMemoryAttachmentRepository.files.get(attachment.id) }

    static let files = FileTable()
    final class FileTable: @unchecked Sendable {
        private let lock = NSLock(); private var map: [UUID: URL] = [:]
        func set(_ id: UUID, _ u: URL) { lock.lock(); map[id] = u; lock.unlock() }
        func get(_ id: UUID) -> URL? { lock.lock(); defer { lock.unlock() }; return map[id] }
    }
}

// MARK: - Settings

public struct InMemorySettingsRepository: SettingsRepository {
    public let store: InMemoryStore
    public init(store: InMemoryStore) { self.store = store }
    public func load() async -> AppSettings { store.read { $0.settings } }
    public func save(_ settings: AppSettings) async { store.write(events: [.settingsChanged]) { $0.settings = settings } }
    public func observe() -> AsyncStream<AppSettings> { store.observe { $0.settings } }
}

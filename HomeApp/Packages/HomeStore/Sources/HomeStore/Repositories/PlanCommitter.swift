import Foundation
import GRDB
import HomeCore
import PlanKit

/// Writes any `PlanDraft` in one transaction (LLD §6.13): temp ids → UUIDs, alignment applied, interior spaces
/// welded per level (PlanKit `Weld`), accepted suggestions only, rows + outbox + FTS. The CloudKit zone for the
/// property is created by HomeSync when it first sends a record of that property.
public struct PlanCommitter: PlanCommitting {
    public let db: AppDatabase
    public let files: AttachmentFileStore
    public init(_ db: AppDatabase, files: AttachmentFileStore) { self.db = db; self.files = files }

    public func commit(_ draft: PlanDraft, into property: UUID, acceptedSuggestions: Set<UUID>) async throws -> [UUID] {
        let now = db.clock.now
        // Pre-assign ids and copy underlay files outside the transaction (file I/O).
        let levelIds = draft.levels.map { _ in UUID() }
        var prepared: [Int: Attachment] = [:]
        for (i, ld) in draft.levels.enumerated() {
            guard let u = ld.underlay else { continue }
            prepared[i] = try AttachmentStore.prepare(u.image, ownerType: .level, ownerId: levelIds[i], property: property, files: files, now: now)
        }
        let underlays = prepared
        let files = self.files
        do {
            try await db.write { tx in
                guard var prop = try tx.get(Property.self, property, includeDeleted: false) else {
                    throw RepositoryError.notFound(RecordRef(.property, property))
                }
                for (i, ld) in draft.levels.enumerated() {
                    let levelId = levelIds[i]
                    // Level first (attachment has no FK to level; level references the attachment → insert both, level last).
                    var level = Level(id: levelId, propertyId: property, name: ld.name, kind: ld.kind, sortOrder: ld.sortOrder,
                                      underlayTransform: ld.underlay?.transform, georef: ld.georef, createdAt: now, updatedAt: now)
                    if let a = underlays[i] {
                        try AttachmentStore.insert(a, in: tx)
                        level.underlayAttachmentId = a.id
                    }
                    try tx.save(level)

                    let t = ld.alignment ?? .identity
                    var spaceMap: [UUID: UUID] = [:]
                    var spaces: [Space] = []
                    for (n, sd) in ld.spaces.enumerated() {
                        let id = UUID(); spaceMap[sd.tempId] = id
                        spaces.append(Space(id: id, propertyId: property, levelId: levelId, name: sd.name, spaceType: sd.spaceType,
                                            isExterior: sd.isExterior, polygon: sd.polygon.transformed(by: t), source: sd.source,
                                            isApproximate: sd.isApproximate, colorHex: sd.colorHex, sortOrder: n,
                                            createdAt: now, updatedAt: now))
                    }
                    // Weld interior rooms so shared walls coincide (§6.5); failed welds keep the pre-weld polygon.
                    let interiorIdx = spaces.indices.filter { !spaces[$0].isExterior }
                    if interiorIdx.count > 1 {
                        let welded = Weld.weldDetailed(polygons: interiorIdx.map { spaces[$0].polygon })
                        for (k, idx) in interiorIdx.enumerated() where !welded.failedIndices.contains(k) {
                            spaces[idx].polygon = welded.polygons[k]
                        }
                    }
                    for s in spaces { try tx.save(s) }

                    var openingMap: [UUID: UUID] = [:]
                    for od in ld.openings {
                        let id = UUID(); openingMap[od.tempId] = id
                        try tx.save(Opening(id: id, propertyId: property, levelId: levelId, spaceId: od.spaceTempId.flatMap { spaceMap[$0] },
                                            kind: od.kind, segment: t.apply(od.segment), heightIn: od.heightIn, sillIn: od.sillIn,
                                            swing: od.swing, isExteriorDoor: od.isExteriorDoor,
                                            source: draft.source == .roomplan ? .roomplan : .manual, createdAt: now, updatedAt: now))
                    }
                    for md in ld.measurements {
                        let spaceId = md.spaceTempId.flatMap { spaceMap[$0] }, openingId = md.openingTempId.flatMap { openingMap[$0] }
                        let m = HomeMeasurement(propertyId: property, label: md.label, kind: md.kind, spaceId: spaceId, openingId: openingId,
                                                pin: md.pin.map(t.apply), segment: md.segment.map(t.apply), dims: md.dims,
                                                isDeliveryPath: md.isDeliveryPath, source: md.source, createdAt: now, updatedAt: now)
                        guard m.isValid else { continue }
                        try tx.save(m)
                    }
                    for st in ld.suggestedThings where acceptedSuggestions.contains(st.tempId) {
                        let scope: Scope = st.spaceTempId.flatMap { spaceMap[$0] }.map { .space($0, level: levelId) } ?? .level(levelId)
                        try tx.save(Thing(propertyId: property, scope: scope, category: st.category, name: st.name, templateKey: st.templateKey,
                                          dims: st.dims, pin: st.pin.map(t.apply), createdAt: now, updatedAt: now))
                    }
                    tx.emit(.geometryChanged(levelId: levelId))
                }
                if prop.defaultLevelId == nil {
                    prop.defaultLevelId = try PlanStore.levels(tx.db, property: property).defaultLevel(preferred: nil)?.id
                    try tx.save(prop)
                }
            }
        } catch {
            for a in underlays.values { files.remove(id: a.id, ext: a.fileExt) }
            throw error
        }
        return levelIds
    }
}

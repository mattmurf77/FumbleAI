import Foundation

public enum ProjectCSVDisposition: Equatable, Sendable {
    case ready
    case duplicate
    case conflict(String)
}

public struct ProjectCSVDecision: Identifiable, Sendable {
    public let item: ProjectCSVItem
    public let disposition: ProjectCSVDisposition
    public var id: Int { item.id }
}

/// Reused in previews and within the final database transaction so a concurrent import cannot double-count work.
public enum ProjectCSVBatch {
    private struct Key: Hashable {
        let title: String
        let date: String
        init(_ title: String, day: LocalDate?, year: Int?) {
            self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            date = day?.description ?? year.map(String.init) ?? ""
        }
    }

    public static func review(_ items: [ProjectCSVItem], property: Property, existing: [Project],
                              alreadyImported: (ProjectCSVItem) -> Bool) throws -> [ProjectCSVDecision] {
        guard items.count <= ProjectCSV.maxRows, Set(items.map(\.id)).count == items.count else {
            throw ProjectCSVError("The import contains too many rows or repeated row identifiers.")
        }
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        var byKey = Dictionary(grouping: existing.filter { $0.propertyId == property.id && $0.status == .done }) {
            Key($0.title, day: $0.completedOn, year: $0.completedYear)
        }
        var seen = Set<String>()
        return try items.map { row in
            try row.validate(currency: property.currencyCode)
            let key = Key(row.title, day: row.day, year: row.year)
            let disposition: ProjectCSVDisposition
            if alreadyImported(row) || seen.contains(row.signature) {
                disposition = .duplicate
            } else {
                let candidates: [Project]
                if let id = row.sourceID, let project = byID[id] { candidates = [project] }
                else { candidates = byKey[key, default: []] }
                if candidates.contains(where: { matches(row, project: $0, property: property) }) {
                    disposition = .duplicate
                } else if !candidates.isEmpty {
                    disposition = .conflict("A project with this ID or title and completion date already exists with different details. Existing work is preserved.")
                } else {
                    disposition = .ready
                    let p = row.makeProject(property: property, now: Date(timeIntervalSince1970: 0))
                    byID[p.id] = p
                    byKey[key, default: []].append(p)
                }
            }
            if disposition == .ready || disposition == .duplicate { seen.insert(row.signature) }
            return ProjectCSVDecision(item: row, disposition: disposition)
        }
    }

    private static func matches(_ row: ProjectCSVItem, project p: Project, property: Property) -> Bool {
        guard p.propertyId == property.id, p.status == .done, p.deletedAt == nil else { return false }
        let prior = ProjectCSVItem(row: 0, title: p.title, day: p.completedOn, year: p.completedYear,
                                   cost: p.actualCost, vendor: p.vendor, action: p.workAction, notes: p.notes)
        return prior.signature == row.signature
    }
}

import Foundation

/// A completed project's owner-facing history. Only the selected title, date, cost and document count may reach a brief.
public struct HomeHistoryEntry: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let date: LocalDate?
    public let completedYear: Int?
    public let actual: Money?
    public let fileCount: Int
    public let hasReceipt: Bool

    public static func history(propertyId: UUID, projects: [Project], lines: [CostLineItem], attachments: [Attachment], documentLinks: [UUID: UUID] = [:]) -> [Self] {
        let finished = projects.filter { $0.propertyId == propertyId && $0.deletedAt == nil && $0.status == .done }
        let eligible = Set(finished.map(\.id))
        let activeLines = lines.filter { $0.propertyId == propertyId && $0.deletedAt == nil && eligible.contains($0.projectId) }
        let costs = Dictionary(grouping: activeLines, by: \.projectId)
        let lineOwners = Dictionary(activeLines.map { ($0.id, $0.projectId) }, uniquingKeysWith: { first, _ in first })
        var counts: [UUID: Int] = [:], receiptOwners = Set<UUID>()
        for file in attachments where file.propertyId == propertyId && file.deletedAt == nil {
            let owner: UUID?
            switch file.ownerType {
            case .property: owner = documentLinks[file.id].flatMap { eligible.contains($0) ? $0 : nil }
            case .project: owner = eligible.contains(file.ownerId) ? file.ownerId : nil
            case .costLineItem: owner = lineOwners[file.ownerId]
            default: owner = nil
            }
            if let owner {
                counts[owner, default: 0] += 1
                if file.kind == .receipt { receiptOwners.insert(owner) }
            }
        }
        return finished.map { p in
            Self(id: p.id, title: p.title, date: p.completedOn, completedYear: p.completedOn?.year ?? p.completedYear, actual: effectiveCost(p, lines: costs[p.id, default: []]),
                 fileCount: counts[p.id, default: 0], hasReceipt: receiptOwners.contains(p.id))
        }.sorted {
            if $0.completedYear != $1.completedYear { return ($0.completedYear ?? 0) > ($1.completedYear ?? 0) }
            if $0.date == $1.date { return ($0.title, $0.id.uuidString) < ($1.title, $1.id.uuidString) }
            return ($0.date ?? LocalDate(1, 1, 1)) > ($1.date ?? LocalDate(1, 1, 1))
        }
    }

    private static func effectiveCost(_ project: Project, lines: [CostLineItem]) -> Money? {
        if let actual = project.actualCost { return actual }
        guard let currency = lines.first?.amount.currency else { return nil }
        var cents: Int64 = 0
        for line in lines {
            let (next, overflow) = cents.addingReportingOverflow(line.amount.cents)
            guard !overflow, line.amount.currency == currency else { return nil }
            cents = next
        }
        return Money(cents: cents, currency: currency)
    }
}

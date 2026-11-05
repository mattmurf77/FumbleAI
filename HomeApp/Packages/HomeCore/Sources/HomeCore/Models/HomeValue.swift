import Foundation

/// An owner-entered source for value, kept locally on this device against the owning property.
public struct HomeValueReference: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, ForwardCompatibleEnum {
        case appraisal, agentOpinion, onlineEstimate, purchasePrice, comparableSale, unknown
        public static var unknownCase: Self { .unknown }
        public var label: String {
            switch self {
            case .appraisal: return "Appraisal"
            case .agentOpinion: return "Agent opinion"
            case .onlineEstimate: return "Online estimate"
            case .purchasePrice: return "My purchase price"
            case .comparableSale: return "Comparable sale"
            case .unknown: return "Other reference"
            }
        }
        public var estimatesThisHome: Bool { self == .appraisal || self == .agentOpinion || self == .onlineEstimate }
    }
    public let id: UUID
    public let propertyId: UUID
    public var kind: Kind
    public var source: String
    public var asOf: LocalDate
    public var amount: Money
    public var upper: Money?

    public init(id: UUID = UUID(), propertyId: UUID, kind: Kind, source: String, asOf: LocalDate, amount: Money, upper: Money? = nil) {
        self.id = id; self.propertyId = propertyId; self.kind = kind; self.source = source
        self.asOf = asOf; self.amount = amount; self.upper = upper
    }
    public func validate() throws {
        guard kind != .unknown, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, source.count <= 240 else {
            throw HomeValueProblem("Choose a reference type and enter its source (up to 240 characters).")
        }
        guard LocalDate(string: asOf.description) == asOf, amount.cents > 0, amount.currency.count == 3 else {
            throw HomeValueProblem("Supply a valid date and a positive amount in the home's currency.")
        }
        if let upper, !kind.estimatesThisHome || upper.currency != amount.currency || upper.cents < amount.cents {
            throw HomeValueProblem("Use an upper amount only for a range, in the same currency and at least as large as the lower amount.")
        }
    }
}

public struct HomeValueProblem: LocalizedError, Sendable {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
    public static var conflict: Self { Self("This reference changed. Close the editor and reopen the latest version.") }
}

/// Projection from the existing project ledger. Planned costs, notes, addresses, vendor and files never enter this type.
public struct CompletedInvestment: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let date: LocalDate?
    public let actual: Money?
}

public struct HomeValueSnapshot: Equatable, Sendable {
    public let references: [HomeValueReference]
    public let investments: [CompletedInvestment]
    public var latestEstimate: HomeValueReference? { references.first { $0.kind.estimatesThisHome } }

    public init(propertyId: UUID, references: [HomeValueReference], projects: [Project], lines: [CostLineItem]) {
        self.references = references.filter { $0.propertyId == propertyId }.sorted {
            $0.asOf == $1.asOf ? $0.id.uuidString < $1.id.uuidString : $0.asOf > $1.asOf
        }
        let costs = Dictionary(grouping: lines.filter { $0.propertyId == propertyId && $0.deletedAt == nil }, by: \.projectId)
        investments = projects.filter { $0.propertyId == propertyId && $0.status == .done && $0.deletedAt == nil }.map { p in
            let items = costs[p.id, default: []]
            var actual = p.actualCost
            if actual == nil, let currency = items.first?.amount.currency, items.allSatisfy({ $0.amount.currency == currency }) {
                var cents: Int64 = 0
                for line in items {
                    let (next, overflow) = cents.addingReportingOverflow(line.amount.cents)
                    guard !overflow else { return CompletedInvestment(id: p.id, title: p.title, date: p.completedOn, actual: nil) }
                    cents = next
                }
                actual = Money(cents: cents, currency: currency)
            }
            return CompletedInvestment(id: p.id, title: p.title, date: p.completedOn, actual: actual)
        }.sorted {
            if $0.date == $1.date { return ($0.title, $0.id.uuidString) < ($1.title, $1.id.uuidString) }
            return ($0.date ?? LocalDate(1, 1, 1)) > ($1.date ?? LocalDate(1, 1, 1))
        }
    }
}

public protocol HomeValueRepository: Sendable {
    func observe(propertyId: UUID) -> AsyncStream<HomeValueSnapshot>
    func save(_ item: HomeValueReference, replacing original: HomeValueReference?) async throws
    func remove(_ original: HomeValueReference) async throws
}

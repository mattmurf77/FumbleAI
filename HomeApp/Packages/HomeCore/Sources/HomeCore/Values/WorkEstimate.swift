import Foundation

/// A planning worksheet. A blank price is unknown; explicit zero means the homeowner expects no charge.
public struct WorkEstimateLine: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, CaseIterable, Codable, Sendable { case material, labor, equipment, fee, wholeJob }
    public var id: UUID
    public var kind: Kind
    public var name: String
    public var quantity: Decimal?
    public var unit: String
    public var confirmedOnHand: Decimal?
    public var packSize: Decimal?
    public var unitPrice: Money?
    public var highUnitPrice: Money?
    public var source: String?

    public init(id: UUID = UUID(), kind: Kind, name: String, quantity: Decimal? = nil, unit: String = "ea",
                confirmedOnHand: Decimal? = nil, packSize: Decimal? = nil, unitPrice: Money? = nil,
                highUnitPrice: Money? = nil, source: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.confirmedOnHand = confirmedOnHand
        self.packSize = packSize
        self.unitPrice = unitPrice
        self.highUnitPrice = highUnitPrice
        self.source = source
    }
}

public struct WorkEstimateTotals: Equatable, Sendable {
    public var knownLow: Money?
    public var knownHigh: Money?
    public var unpricedLineCount = 0
    public var ownHours: Decimal = 0
    public var hasUnknownOwnHours = false
    public var isComplete: Bool { knownLow != nil && unpricedLineCount == 0 }
}

public struct WorkEstimateError: LocalizedError, Sendable {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}

public struct WorkEstimate: Hashable, Codable, Sendable {
    public var mode: Chore.WorkMode
    public var currency: String
    public var lines: [WorkEstimateLine]
    public var scopeQuantity: Decimal?
    public var scopeUnit: String
    public var assumptions: String?

    public init(mode: Chore.WorkMode, currency: String, lines: [WorkEstimateLine] = [],
                scopeQuantity: Decimal? = nil, scopeUnit: String = "", assumptions: String? = nil) {
        self.mode = mode
        self.currency = currency
        self.lines = lines
        self.scopeQuantity = scopeQuantity
        self.scopeUnit = scopeUnit
        self.assumptions = assumptions
    }

    /// Quantity in priced units: material packs when a pack size was entered, otherwise natural units or hours.
    public func purchaseQuantity(for line: WorkEstimateLine) throws -> Decimal? {
        for number in [line.quantity, line.packSize].compactMap({ $0 }) {
            guard !number.isNaN, number >= Decimal(sign: .plus, exponent: -9, significand: 1), number <= 1_000_000_000 else {
                throw WorkEstimateError("Enter a positive quantity between 0.000000001 and one billion.")
            }
        }
        if let onHand = line.confirmedOnHand, (onHand.isNaN || onHand < 0 || onHand > 1_000_000_000) {
            throw WorkEstimateError("Enter a nonnegative usable stock count of at most one billion.")
        }
        let acceptsStock = line.kind == .material || (line.kind == .equipment && ChoreSupply.unitKey(line.unit) == "ea")
        guard (acceptsStock || line.confirmedOnHand == nil), (line.kind == .material || line.packSize == nil) else {
            throw WorkEstimateError("Apply usable stock only to materials or counted tools. Pack sizes apply to materials.")
        }
        guard let required = line.quantity else { return nil }
        guard acceptsStock else { return required }
        let missing = max(0, required - (line.confirmedOnHand ?? 0))
        guard let pack = line.packSize else { return missing }
        var divided = missing / pack
        var whole = Decimal()
        NSDecimalRound(&whole, &divided, 0, .up)
        return whole
    }

    public func totals() throws -> WorkEstimateTotals {
        guard currency.utf8.count == 3, currency.utf8.allSatisfy({ (65...90).contains($0) }) else {
            throw WorkEstimateError("Choose a three-letter currency.")
        }
        guard lines.count <= 200, Set(lines.map(\.id)).count == lines.count else {
            throw WorkEstimateError("Use at most 200 distinct estimate lines.")
        }
        if lines.count > 1 && lines.contains(where: { $0.kind == .wholeJob }) {
            throw WorkEstimateError("Use a whole-job price on its own or replace it with individual costs.")
        }
        guard scopeUnit.count <= 80, (assumptions?.count ?? 0) <= 8_000 else { throw WorkEstimateError("Shorten the scope unit or notes.") }
        if let scopeQuantity, scopeQuantity.isNaN || scopeQuantity <= 0 || scopeQuantity > 1_000_000_000 {
            throw WorkEstimateError("Enter a positive scope quantity of at most one billion.")
        }

        var result = WorkEstimateTotals()
        var lowCents: Decimal = 0
        var highCents: Decimal = 0
        var hasKnownCost = false
        for line in lines {
            guard !line.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, line.name.count <= 300,
                  line.unit.count <= 80, (line.source?.count ?? 0) <= 2_000 else { throw WorkEstimateError("Give each line a name and shorten long descriptions.") }
            let units = try purchaseQuantity(for: line)
            for price in [line.unitPrice, line.highUnitPrice].compactMap({ $0 }) {
                guard price.currency == currency, price.cents >= 0 else { throw WorkEstimateError("Use nonnegative prices in \(currency) throughout this estimate.") }
            }
            if let high = line.highUnitPrice, line.unitPrice.map({ high.cents >= $0.cents }) != true {
                throw WorkEstimateError("Enter a low price before its equal or higher upper price.")
            }
            if line.kind == .labor && mode == .diy {
                if let units { result.ownHours += units } else { result.hasUnknownOwnHours = true }
                hasKnownCost = true
                continue
            }
            if units == 0 { hasKnownCost = true; continue }
            guard let units, let price = line.unitPrice else { result.unpricedLineCount += 1; continue }
            lowCents += roundedCents(units: units, price: price)
            highCents += roundedCents(units: units, price: line.highUnitPrice ?? price)
            guard !highCents.isNaN, highCents <= Decimal(Int64.max) else { throw WorkEstimateError("This estimate exceeds the supported amount.") }
            hasKnownCost = true
        }
        if hasKnownCost {
            result.knownLow = Money(cents: NSDecimalNumber(decimal: lowCents).int64Value, currency: currency)
            result.knownHigh = Money(cents: NSDecimalNumber(decimal: highCents).int64Value, currency: currency)
        }
        return result
    }

    private func roundedCents(units: Decimal, price: Money) -> Decimal {
        var extended = units * Decimal(price.cents)
        var cents = Decimal()
        NSDecimalRound(&cents, &extended, 0, .plain)
        return cents
    }

    public static func validate(_ estimates: [Self], currency: String) throws {
        guard Set(estimates.map(\.mode)).count == estimates.count else { throw WorkEstimateError("Provide one estimate for each work method.") }
        for estimate in estimates {
            guard estimate.currency == currency else { throw WorkEstimateError("Use the record’s currency, \(currency).") }
            _ = try estimate.totals()
        }
    }
}

public enum WorkEstimateOwner: Hashable, Sendable {
    case chore(UUID), project(UUID)
}

public protocol WorkEstimateRepository: Sendable {
    func estimates(owner: WorkEstimateOwner, propertyId: UUID) async throws -> [WorkEstimate]
    func saveEstimates(_ estimates: [WorkEstimate], owner: WorkEstimateOwner, propertyId: UUID) async throws
}

public extension WorkEstimateRepository {
    func saveEstimate(_ estimate: WorkEstimate, owner: WorkEstimateOwner, propertyId: UUID) async throws {
        try await saveEstimates([estimate], owner: owner, propertyId: propertyId)
    }
}

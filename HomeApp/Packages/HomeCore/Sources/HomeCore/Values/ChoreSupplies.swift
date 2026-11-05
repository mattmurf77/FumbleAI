import Foundation

public extension Chore {
    enum WorkMode: String, Codable, CaseIterable, Sendable { case diy, hirePro
        public var label: String { self == .diy ? "DIY" : "Hire a pro" }
    }
}

public struct ChoreSupply: Hashable, Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var quantity: Int
    public var unit: String
    public var isEquipment: Bool
    public var confirmedOnHand: Int?
    public var requested: Bool
    public init(id: UUID = UUID(), name: String, quantity: Int = 1, unit: String = "ea", isEquipment: Bool = false,
                confirmedOnHand: Int? = nil, requested: Bool = false) {
        self.id = id; self.name = name; self.quantity = quantity; self.unit = unit; self.isEquipment = isEquipment
        self.confirmedOnHand = confirmedOnHand; self.requested = requested
    }
    public static func suggestions(_ names: [String]) -> [Self] {
        var seen = Set<String>()
        return names.compactMap { name in
            let title = name.trimmingCharacters(in: .whitespacesAndNewlines), key = normalize(title)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return Self(name: title)
        }
    }
    public static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    public static func unitKey(_ text: String?) -> String {
        let key = normalize(text ?? "")
        return ["", "ea", "each", "piece", "pieces", "unit", "units"].contains(key) ? "ea" : key
    }
    public var key: String { Self.normalize(name) + "\u{1f}" + Self.unitKey(unit) }
    public static func validate(_ plan: [Self]) throws {
        guard plan.count <= 75, Set(plan.map(\.id)).count == plan.count, Set(plan.map(\.key)).count == plan.count,
              plan.allSatisfy({ !normalize($0.name).isEmpty && $0.name.count <= 120 && $0.unit.count <= 24 && (1...9_999).contains($0.quantity) && (0...9_999).contains($0.confirmedOnHand ?? 0) })
        else { throw ChoreSupplyError("Give each supply or tool a distinct name and unit, with a quantity from 1 to 9,999.") }
    }
    public func matches(_ item: InventoryItem) -> Bool { Self.normalize(item.name) == Self.normalize(name) && Self.unitKey(item.unit) == Self.unitKey(unit) }
}

public struct ChoreSupplyError: LocalizedError, Sendable {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}

public struct SupplyReadiness: Sendable {
    public let inventory: [InventoryItem]
    public let equipment: [Thing]
    public let onHand: Double?
    public init(_ supply: ChoreSupply, propertyId: UUID, inventory: [InventoryItem], things: [Thing]) {
        self.inventory = inventory.filter { $0.deletedAt == nil && $0.propertyId == propertyId && supply.matches($0) }
        equipment = ChoreSupply.unitKey(supply.unit) != "ea" ? [] : things.filter {
            $0.deletedAt == nil && $0.propertyId == propertyId && $0.ownership == .owned && ChoreSupply.normalize($0.name) == ChoreSupply.normalize(supply.name)
        }
        // The same tool may be described both as a Thing and as stock. Use the better-supported count once.
        if let confirmed = supply.confirmedOnHand { onHand = Double(confirmed) }
        else if self.inventory.isEmpty && equipment.isEmpty { onHand = nil }
        else { onHand = max(self.inventory.reduce(0.0) { $0 + max(0, $1.quantity) }, Double(equipment.count)) }
    }
}

public enum ChoreShopping {
    /// Consumables add across open tasks; reusable equipment needs the highest requested count only.
    public static func lines(property: UUID, chores: [Chore], inventory: [InventoryItem], things: [Thing]) -> [ShoppingLine] {
        let selected = chores.filter { $0.propertyId == property && $0.isOpen && $0.workMode == .diy }.flatMap { c in
            (c.supplyPlan ?? []).filter(\.requested).map { (c.id, $0) }
        }
        return Dictionary(grouping: selected, by: { $0.1.key }).compactMap { key, group in
            guard let first = group.min(by: { $0.1.id.uuidString < $1.1.id.uuidString }) else { return nil }
            let items = group.map { $0.1 }
            let required = items.filter { !$0.isEquipment }.reduce(0) { $0 + $1.quantity } + (items.filter(\.isEquipment).map(\.quantity).max() ?? 0)
            let observed = items.compactMap(\.confirmedOnHand).max().map(Double.init) ?? SupplyReadiness(first.1, propertyId: property, inventory: inventory, things: things).onHand ?? 0
            let needed = ceil(max(0, Double(required) - observed))
            guard needed > 0 else { return nil }
            var line = ShoppingLine(reason: .toDoSupply, ref: .chore(first.0), label: first.1.name, quantity: needed, unit: ChoreSupply.unitKey(first.1.unit))
            line.supplyKey = key
            return line
        }.sorted { ($0.label, $0.id) < ($1.label, $1.id) }
    }
    public static func merged(existing: [ShoppingLine], supplies: [ShoppingLine]) -> [ShoppingLine] {
        let requested = Set(supplies.compactMap(\.supplyKey))
        return supplies + existing.filter { !requested.contains(ChoreSupply(name: $0.label, unit: $0.unit ?? "ea").key) }
    }
    /// Produce a single atomic change. A stale/retried tap never increments inventory twice.
    public static func purchase(_ line: ShoppingLine, property: UUID, chores: [Chore], inventory: [InventoryItem], things: [Thing]) throws -> (InventoryItem, [Chore]) {
        guard line.reason == .toDoSupply, let key = line.supplyKey, let units = line.quantity,
              let live = lines(property: property, chores: chores, inventory: inventory, things: things).first(where: { $0.supplyKey == key }), live == line else { throw ChoreSupplyError("The list changed. Check the current quantity before recording a purchase.") }
        let supply = ChoreSupply(name: line.label, unit: line.unit ?? "ea")
        var changedItem = inventory.filter { $0.propertyId == property && $0.deletedAt == nil && supply.matches($0) }
            .sorted { ($0.isLow ? 0 : 1, $0.id.uuidString) < ($1.isLow ? 0 : 1, $1.id.uuidString) }.first
            ?? InventoryItem(propertyId: property, kind: .stored, name: line.label, scope: .property, quantity: 0, unit: line.unit)
        changedItem.quantity += units; changedItem.isLow = false
        let updates: [Chore] = chores.compactMap { chore in
            guard chore.propertyId == property, chore.isOpen, chore.workMode == .diy, var plan = chore.supplyPlan,
                  plan.contains(where: { $0.key == key && $0.requested }) else { return nil }
            var updated = chore
            for i in plan.indices where plan[i].key == key && plan[i].requested {
                plan[i].requested = false
                if plan[i].confirmedOnHand != nil { plan[i].confirmedOnHand = nil }
            }
            updated.supplyPlan = plan; return updated
        }
        return (InventoryLogic.applyLowThreshold(changedItem), updates)
    }
}

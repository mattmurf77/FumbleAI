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
        // An installed asset is not a consumable spare. Only reusable, individually counted tools
        // can use an owned Thing as evidence; planned purchases never contribute.
        equipment = !supply.isEquipment || ChoreSupply.unitKey(supply.unit) != "ea" ? [] : things.filter {
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
        let openPlans = chores.filter { $0.propertyId == property && $0.isOpen && $0.workMode == .diy }.flatMap { c in
            (c.supplyPlan ?? []).map { (choreID: c.id, title: c.title, supply: $0) }
        }
        return Dictionary(grouping: openPlans, by: { $0.supply.key }).compactMap { key, group in
            let requested = group.filter { $0.supply.requested }
            guard let first = requested.min(by: { $0.choreID.uuidString < $1.choreID.uuidString }) else { return nil }
            var line = ShoppingLine(reason: .toDoSupply, ref: .chore(first.choreID), label: first.supply.name,
                                    unit: ChoreSupply.unitKey(first.supply.unit))
            line.supplyKey = key
            let reports = group.compactMap { task in
                task.supply.confirmedOnHand.map { ShoppingLine.StockReport(id: task.choreID, taskTitle: task.title, count: $0) }
            }
            let counts = Set(reports.map(\.count))
            if counts.count > 1 {
                line.conflictingCounts = reports.sorted { ($0.taskTitle, $0.id.uuidString) < ($1.taskTitle, $1.id.uuidString) }
                return line
            }
            let items = requested.map(\.supply)
            let consumables = items.filter { !$0.isEquipment }.reduce(0) { $0 + $1.quantity }
            let reusable = items.filter(\.isEquipment).map(\.quantity).max() ?? 0
            let required = consumables + reusable
            var catalogMatch = first.supply
            catalogMatch.isEquipment = reusable > 0
            let stock = SupplyReadiness(catalogMatch, propertyId: property, inventory: inventory, things: things)
            let catalogUnits = stock.inventory.reduce(0.0) { $0 + max(0, $1.quantity) }
            // Owned Things can cover only the reusable demand, even when the same name/unit is
            // marked reusable in one plan and consumable in another.
            let available = max(catalogUnits, Double(min(reusable, stock.equipment.count)))
            let observed = items.compactMap(\.confirmedOnHand).first.map(Double.init) ?? available
            let needed = ceil(max(0, Double(required) - observed))
            guard needed > 0 else { return nil }
            line.quantity = needed
            line.supplyStockID = destination(for: stock.inventory)?.id
            return line
        }.sorted { ($0.label, $0.id) < ($1.label, $1.id) }
    }
    private static func destination(for matches: [InventoryItem]) -> InventoryItem? {
        if matches.count == 1, let only = matches.first, only.ownerId == nil { return only }
        let shared = matches.filter { $0.scope == .property && $0.storageSpotId == nil && $0.ownerId == nil && $0.linkedThingId == nil }
        return shared.count == 1 ? shared.first : nil
    }

    public static func merged(existing: [ShoppingLine], supplies: [ShoppingLine]) -> [ShoppingLine] {
        let replenished = Set(supplies.compactMap(\.supplyStockID))
        return supplies + existing.filter { line in
            guard line.reason == .low, case .inventory(let id) = line.ref else { return true }
            return !replenished.contains(id)
        }
    }
    /// Produce a single atomic change. A stale/retried tap never increments inventory twice.
    public static func purchase(_ line: ShoppingLine, property: UUID, chores: [Chore], inventory: [InventoryItem], things: [Thing]) throws -> (InventoryItem, [Chore]) {
        let stale = ChoreSupplyError("The list changed. Check the current quantity before recording a purchase.")
        guard line.reason == .toDoSupply, let key = line.supplyKey,
              let live = lines(property: property, chores: chores, inventory: inventory, things: things).first(where: { $0.supplyKey == key })
        else { throw stale }
        guard live.conflictingCounts == nil else {
            throw ChoreSupplyError("The saved on-hand counts disagree. Review the matching to-dos in your Shopping list.")
        }
        guard live == line, let units = live.quantity else { throw stale }
        let supply = ChoreSupply(name: line.label, unit: line.unit ?? "ea")
        let matches = inventory.filter { $0.propertyId == property && $0.deletedAt == nil && supply.matches($0) }
        // Multiple possible bins do not identify where the purchase was put. Keep existing quantities,
        // owners and storage paths intact and place the new units at whole-property scope.
        var changedItem = matches.first(where: { $0.id == line.supplyStockID }) ?? InventoryItem(propertyId: property, kind: .stored, name: line.label,
                                                        scope: .property, quantity: 0, unit: line.unit)
        changedItem.quantity += units
        changedItem.isLow = false
        let afterInventory = matches.filter { $0.id != changedItem.id } + [changedItem]
        let updates: [Chore] = chores.compactMap { chore in
            guard chore.propertyId == property, chore.isOpen, chore.workMode == .diy, var plan = chore.supplyPlan,
                  let index = plan.firstIndex(where: { $0.key == key }), plan[index].requested || plan[index].confirmedOnHand != nil else { return nil }
            let original = plan[index]
            let before = SupplyReadiness(original, propertyId: property, inventory: matches, things: things).onHand ?? 0
            plan[index].requested = false
            plan[index].confirmedOnHand = nil
            let after = SupplyReadiness(plan[index], propertyId: property, inventory: afterInventory, things: things).onHand ?? 0
            // Preserve checked stock outside the catalog. A purchase adds just the bought quantity to
            // inventory. If the catalog alone now accounts for it all, resume live catalog counts.
            if (original.confirmedOnHand != nil || original.isEquipment), abs(before + units - after) > 0.000_001 {
                plan[index].confirmedOnHand = Int(min(9_999, max(0, floor(before + units))))
            }
            var updated = chore
            updated.supplyPlan = plan
            return updated
        }
        return (InventoryLogic.applyLowThreshold(changedItem), updates)
    }
}

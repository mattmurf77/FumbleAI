import Foundation
import HomeCore
import GRDB

extension ChoreStore {
    static func putPreparation(_ chore: Chore, in tx: StoreTx) throws {
        let supplies = chore.supplyPlan ?? []
        try ChoreSupply.validate(supplies)
        if chore.workMode == nil && chore.guideID == nil && supplies.isEmpty {
            try tx.db.execute(sql: "DELETE FROM chore_preparation WHERE chore_id=?", arguments: [chore.id.db]); return
        }
        let encoded = supplies.isEmpty ? nil : try HomeJSON.encodeString(supplies)
        try tx.db.execute(sql: "INSERT INTO chore_preparation(chore_id,work_mode,guide_id,supplies_json) VALUES (?,?,?,?) ON CONFLICT(chore_id) DO UPDATE SET work_mode=excluded.work_mode,guide_id=excluded.guide_id,supplies_json=excluded.supplies_json", arguments: [chore.id.db, chore.workMode?.rawValue, chore.guideID, encoded])
    }
}

extension InventoryStore {
    public func buySelectedSupply(_ line: ShoppingLine, propertyId: UUID) async throws {
        try await db.write { tx in
            let (item, chores) = try ChoreShopping.purchase(line, property: propertyId, chores: ChoreStore.query(tx.db, .init(propertyId: propertyId)), inventory: InventoryItem.fetchAll(tx.db, where: "property_id = ?", [propertyId.db]), things: Thing.fetchAll(tx.db, where: "property_id = ?", [propertyId.db]))
            try tx.save(item)
            for chore in chores { try ChoreStore.putPreparation(chore, in: tx) }
            tx.emit(.recordsChanged([RecordRef(.inventoryItem, item.id)]))
        }
    }
}

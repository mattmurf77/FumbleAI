import Foundation
import HomeCore

/// RoomPlan labels → Home vocabulary (LLD §6.12 steps 7 and 9).
public enum RoomPlanLabelMap {
    /// Suggested-Thing mapping for a RoomPlan object category.
    public struct ThingMapping: Hashable, Sendable {
        public var category: Thing.Category
        public var templateKey: String
        public var name: String
    }

    /// Object category (RoomPlan case name) → Thing category / template. `stairs` (and unknown categories) → nil:
    /// stairs are a level-alignment hint, not a Thing.
    public static func thing(forObject category: String) -> ThingMapping? {
        switch normalize(category) {
        case "refrigerator": return ThingMapping(category: .appliance, templateKey: "refrigerator", name: "Refrigerator")
        case "stove": return ThingMapping(category: .appliance, templateKey: "range", name: "Range")
        case "oven": return ThingMapping(category: .appliance, templateKey: "wall_oven", name: "Wall oven")
        case "dishwasher": return ThingMapping(category: .appliance, templateKey: "dishwasher", name: "Dishwasher")
        case "washerdryer": return ThingMapping(category: .appliance, templateKey: "washer", name: "Washer")
        case "television": return ThingMapping(category: .electronic, templateKey: "tv", name: "TV")
        case "sofa": return ThingMapping(category: .furniture, templateKey: "sofa", name: "Sofa")
        case "bed": return ThingMapping(category: .furniture, templateKey: "bed", name: "Bed")
        case "table": return ThingMapping(category: .furniture, templateKey: "table", name: "Table")
        case "chair": return ThingMapping(category: .furniture, templateKey: "chair", name: "Chair")
        case "storage": return ThingMapping(category: .furniture, templateKey: "shelf", name: "Storage")
        case "fireplace": return ThingMapping(category: .system, templateKey: "fireplace", name: "Fireplace")
        case "sink": return ThingMapping(category: .fixture, templateKey: "sink", name: "Sink")
        case "toilet": return ThingMapping(category: .fixture, templateKey: "toilet", name: "Toilet")
        case "bathtub": return ThingMapping(category: .fixture, templateKey: "bathtub", name: "Bathtub")
        default: return nil
        }
    }

    /// Section label → (name, type). `unidentified` / unknown → nil.
    public static func room(forSection label: String) -> (name: String, type: SpaceType)? {
        switch normalize(label) {
        case "bedroom": return ("Bedroom", .bedroom)
        case "bathroom": return ("Bathroom", .bathroom)
        case "kitchen": return ("Kitchen", .kitchen)
        case "livingroom": return ("Living Room", .living)
        case "diningroom": return ("Dining Room", .dining)
        default: return nil
        }
    }

    /// Object-based naming fallback (§6.12 step 7b), checked in this order.
    public static func room(forObjects categories: [String]) -> (name: String, type: SpaceType)? {
        let s = Set(categories.map(normalize))
        if s.contains("toilet") || s.contains("bathtub") { return ("Bathroom", .bathroom) }
        if s.contains("bed") { return ("Bedroom", .bedroom) }
        if !s.isDisjoint(with: ["stove", "oven", "refrigerator", "dishwasher"]) { return ("Kitchen", .kitchen) }
        if s.contains("sofa") && s.contains("television") { return ("Living Room", .living) }
        if s.contains("washerdryer") { return ("Laundry", .laundry) }
        if s.contains("stairs") { return ("Stairs", .stairs) }
        return nil
    }

    /// "Sentence" noun for the review prompt ("We found a refrigerator in Kitchen. Add it?").
    public static func promptNoun(forObject category: String) -> String {
        switch normalize(category) {
        case "washerdryer": return "washer/dryer"
        case "television": return "TV"
        default: return (thing(forObject: category)?.name ?? category).lowercased()
        }
    }

    /// Lowercases and strips everything but letters: "washerDryer", "washer_dryer" → "washerdryer".
    static func normalize(_ s: String) -> String { s.lowercased().filter(\.isLetter) }
}

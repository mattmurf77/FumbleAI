import Foundation
import PlanKit

/// A durable item: appliance, electronic, furniture, fixture or system. LLD §3.2 `thing`.
public struct Thing: SyncedModel {
    public static let recordType = RecordType.thing
    public enum Category: String, ForwardCompatibleEnum {
        case appliance, electronic, furniture, fixture, system, unknown
        public static var unknownCase: Category { .unknown }
    }
    /// Planned things are "plan to buy one" (HLD §9-10): drawn dashed and excluded from counts.
    public enum Ownership: String, ForwardCompatibleEnum {
        case owned, planned, unknown
        public static var unknownCase: Ownership { .unknown }
    }
    public var id: UUID
    public var propertyId: UUID
    public var scope: Scope
    public var category: Category
    public var name: String
    public var ownership: Ownership
    /// 'refrigerator', 'light_fixture', 'hvac_furnace', ... see `ThingTemplate.catalog`.
    public var templateKey: String?
    /// Template fields, e.g. {"bulbBase":"E26","filterSize":"16x25x1","merv":11}.
    public var attributes: [String: JSONValue]
    public var brand: String?
    public var model: String?
    public var serial: String?
    public var purchaseDate: LocalDate?
    public var purchasePrice: Money?
    public var warrantyEnd: LocalDate?
    public var dims: Dims3
    /// The measurement this thing goes into ("Fridge opening").
    public var fitMeasurementId: UUID?
    /// Icon position on the plan (inches).
    public var pin: Vec2?
    public var notes: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: UUID = UUID(), propertyId: UUID, scope: Scope, category: Category, name: String,
                ownership: Ownership = .owned, templateKey: String? = nil, attributes: [String: JSONValue] = [:],
                brand: String? = nil, model: String? = nil, serial: String? = nil, purchaseDate: LocalDate? = nil,
                purchasePrice: Money? = nil, warrantyEnd: LocalDate? = nil, dims: Dims3 = .empty,
                fitMeasurementId: UUID? = nil, pin: Vec2? = nil, notes: String? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id; self.propertyId = propertyId; self.scope = scope; self.category = category; self.name = name
        self.ownership = ownership; self.templateKey = templateKey; self.attributes = attributes
        self.brand = brand; self.model = model; self.serial = serial; self.purchaseDate = purchaseDate
        self.purchasePrice = purchasePrice; self.warrantyEnd = warrantyEnd; self.dims = dims
        self.fitMeasurementId = fitMeasurementId; self.pin = pin; self.notes = notes
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }

    public var template: ThingTemplate? { templateKey.flatMap(ThingTemplate.find) }
    /// SF Symbol for pins (template symbol, else category default).
    public var symbol: String { template?.symbol ?? ThingTemplate.defaultSymbol(for: category) }
}

/// Thing template catalog (spec 06 FR-THG-10; PRD assumption). `/v1/templates` on the Home server may later
/// override this list; the keys are stable identifiers stored in `thing.template_key`.
public struct ThingTemplate: Hashable, Codable, Sendable, Identifiable {
    public struct Field: Hashable, Codable, Sendable {
        public enum Kind: String, Codable, Sendable { case text, number, bool, choice, date }
        public var key: String
        public var label: String
        public var kind: Kind
        public var choices: [String]?
        public init(_ key: String, _ label: String, _ kind: Kind, choices: [String]? = nil) {
            self.key = key; self.label = label; self.kind = kind; self.choices = choices
        }
    }
    public var key: String
    public var name: String
    public var category: Thing.Category
    public var symbol: String
    public var fields: [Field]
    /// Suggested maintenance chore (FR-THG-13).
    public var suggestedChore: SuggestedChore?
    public var id: String { key }

    public struct SuggestedChore: Hashable, Codable, Sendable {
        public var title: String
        public var rule: RepeatRule
    }

    public init(key: String, name: String, category: Thing.Category, symbol: String, fields: [Field] = [], suggestedChore: SuggestedChore? = nil) {
        self.key = key; self.name = name; self.category = category; self.symbol = symbol; self.fields = fields; self.suggestedChore = suggestedChore
    }

    public static func find(_ key: String) -> ThingTemplate? { catalog.first { $0.key == key } }

    public static func defaultSymbol(for c: Thing.Category) -> String {
        switch c {
        case .appliance: return "refrigerator"; case .electronic: return "tv"; case .furniture: return "sofa"
        case .fixture: return "lightbulb"; case .system: return "flame"; case .unknown: return "shippingbox"
        }
    }

    static let filterFields: [Field] = [Field("filterSize", "Filter size", .text), Field("merv", "MERV", .number)]
    static let fuel = ["gas", "electric", "oil", "heat pump"]

    /// v1 catalog.
    public static let catalog: [ThingTemplate] = [
        ThingTemplate(key: "light_fixture", name: "Light fixture", category: .fixture, symbol: "lightbulb", fields: [
            Field("bulbBase", "Bulb base", .choice, choices: ["E26", "E12", "GU10", "GU24", "BR30", "PAR38", "T8", "other"]),
            Field("bulbCount", "Bulb count", .number), Field("wattage", "Wattage / equivalent", .text),
            Field("colorTemp", "Color temperature", .choice, choices: ["2700K", "3000K", "4000K", "5000K"]),
            Field("dimmable", "Dimmable", .bool), Field("smart", "Smart", .bool)]),
        ThingTemplate(key: "hvac_furnace", name: "HVAC furnace / air handler", category: .system, symbol: "fan",
                      fields: filterFields + [Field("filterLocation", "Filter location", .text), Field("fuel", "Fuel", .choice, choices: fuel)],
                      suggestedChore: SuggestedChore(title: "Change furnace filter", rule: RepeatRule(freq: .everyNDays, interval: 90))),
        ThingTemplate(key: "hvac_filter", name: "HVAC filter (return grille)", category: .fixture, symbol: "square.grid.3x3", fields: filterFields,
                      suggestedChore: SuggestedChore(title: "Change filter", rule: RepeatRule(freq: .everyNDays, interval: 90))),
        ThingTemplate(key: "water_heater", name: "Water heater", category: .system, symbol: "flame", fields: [
            Field("type", "Type", .choice, choices: ["tank", "tankless"]), Field("fuel", "Fuel", .choice, choices: fuel),
            Field("capacityGal", "Capacity (gal)", .number)]),
        ThingTemplate(key: "water_filter", name: "Water filter", category: .fixture, symbol: "drop", fields: [Field("filterModel", "Filter model", .text)],
                      suggestedChore: SuggestedChore(title: "Replace water filter", rule: RepeatRule(freq: .monthly, interval: 6))),
        ThingTemplate(key: "fridge_water_filter", name: "Fridge water filter", category: .fixture, symbol: "drop", fields: [Field("filterModel", "Filter model", .text)],
                      suggestedChore: SuggestedChore(title: "Replace fridge water filter", rule: RepeatRule(freq: .monthly, interval: 6))),
        ThingTemplate(key: "smoke_detector", name: "Smoke / CO detector", category: .fixture, symbol: "sensor", fields: [
            Field("type", "Type", .choice, choices: ["smoke", "CO", "combo"]),
            Field("batteryType", "Battery", .choice, choices: ["9V", "AA", "sealed 10-yr"]),
            Field("hardwired", "Hardwired", .bool), Field("installDate", "Install date", .date)],
                      suggestedChore: SuggestedChore(title: "Replace detector battery", rule: RepeatRule(freq: .monthly, interval: 12))),
        ThingTemplate(key: "refrigerator", name: "Refrigerator", category: .appliance, symbol: "refrigerator", fields: [
            Field("style", "Style", .choice, choices: ["French door", "side-by-side", "top freezer", "bottom freezer"]),
            Field("waterLine", "Water line", .bool)]),
        ThingTemplate(key: "range", name: "Range", category: .appliance, symbol: "stove", fields: [Field("fuel", "Fuel", .choice, choices: ["gas", "electric", "induction"])]),
        ThingTemplate(key: "wall_oven", name: "Wall oven", category: .appliance, symbol: "oven", fields: [Field("fuel", "Fuel", .choice, choices: ["gas", "electric"])]),
        ThingTemplate(key: "cooktop", name: "Cooktop", category: .appliance, symbol: "cooktop", fields: [Field("fuel", "Fuel", .choice, choices: ["gas", "electric", "induction"])]),
        ThingTemplate(key: "dishwasher", name: "Dishwasher", category: .appliance, symbol: "dishwasher"),
        ThingTemplate(key: "washer", name: "Washer", category: .appliance, symbol: "washer"),
        ThingTemplate(key: "dryer", name: "Dryer", category: .appliance, symbol: "dryer", fields: [
            Field("ventType", "Vent type", .text), Field("fuel", "Fuel", .choice, choices: ["gas", "electric"])]),
        ThingTemplate(key: "tv", name: "TV", category: .electronic, symbol: "tv", fields: [
            Field("screenSize", "Screen size (in)", .number), Field("mount", "Mount", .choice, choices: ["wall", "stand"])]),
        ThingTemplate(key: "router", name: "Router", category: .electronic, symbol: "wifi.router"),
        ThingTemplate(key: "thermostat", name: "Thermostat", category: .electronic, symbol: "thermometer"),
        ThingTemplate(key: "sofa", name: "Sofa", category: .furniture, symbol: "sofa"),
        ThingTemplate(key: "bed", name: "Bed", category: .furniture, symbol: "bed.double"),
        ThingTemplate(key: "table", name: "Table", category: .furniture, symbol: "table.furniture"),
        ThingTemplate(key: "dresser", name: "Dresser", category: .furniture, symbol: "cabinet"),
        ThingTemplate(key: "chair", name: "Chair", category: .furniture, symbol: "chair"),
        ThingTemplate(key: "desk", name: "Desk", category: .furniture, symbol: "table.furniture"),
        ThingTemplate(key: "shelf", name: "Shelf", category: .furniture, symbol: "books.vertical"),
        ThingTemplate(key: "sump_pump", name: "Sump pump", category: .system, symbol: "drop.triangle"),
        ThingTemplate(key: "dehumidifier", name: "Dehumidifier", category: .system, symbol: "humidity"),
        ThingTemplate(key: "garage_door_opener", name: "Garage door opener", category: .system, symbol: "door.garage.closed"),
        ThingTemplate(key: "fireplace", name: "Fireplace", category: .system, symbol: "fireplace"),
        ThingTemplate(key: "sink", name: "Sink", category: .fixture, symbol: "sink"),
        ThingTemplate(key: "toilet", name: "Toilet", category: .fixture, symbol: "toilet"),
        ThingTemplate(key: "bathtub", name: "Bathtub", category: .fixture, symbol: "bathtub"),
    ]
}

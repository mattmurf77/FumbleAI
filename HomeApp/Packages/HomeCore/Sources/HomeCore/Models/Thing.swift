import Foundation
import PlanKit

/// A durable item: appliance, electronic, furniture, fixture, system or outdoor feature. LLD §3.2 `thing`.
public struct Thing: SyncedModel {
    public static let recordType = RecordType.thing
    public enum Category: String, ForwardCompatibleEnum {
        case appliance, electronic, furniture, fixture, system, outdoor, unknown
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
    /// Extra search words for the template picker ("swing", "gate", "utility"…).
    public var aliases: [String]
    public var id: String { key }

    public struct SuggestedChore: Hashable, Codable, Sendable {
        public var title: String
        public var rule: RepeatRule
    }

    public init(key: String, name: String, category: Thing.Category, symbol: String, fields: [Field] = [], suggestedChore: SuggestedChore? = nil,
                aliases: [String] = []) {
        self.key = key; self.name = name; self.category = category; self.symbol = symbol; self.fields = fields; self.suggestedChore = suggestedChore
        self.aliases = aliases
    }

    private enum CodingKeys: String, CodingKey { case key, name, category, symbol, fields, suggestedChore, aliases }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        name = try c.decode(String.self, forKey: .name)
        category = try c.decode(Thing.Category.self, forKey: .category)
        symbol = try c.decode(String.self, forKey: .symbol)
        fields = try c.decodeIfPresent([Field].self, forKey: .fields) ?? []
        suggestedChore = try c.decodeIfPresent(SuggestedChore.self, forKey: .suggestedChore)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
    }

    public static func find(_ key: String) -> ThingTemplate? { catalog.first { $0.key == key } }

    /// Picker search: case-insensitive match on name, key (underscores as spaces) or an alias.
    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return ([name, key, key.replacingOccurrences(of: "_", with: " ")] + aliases).contains { $0.lowercased().contains(q) }
    }

    public static func defaultSymbol(for c: Thing.Category) -> String {
        switch c {
        case .appliance: return "refrigerator"; case .electronic: return "tv"; case .furniture: return "sofa"
        case .fixture: return "lightbulb"; case .system: return "flame"; case .outdoor: return "tree"; case .unknown: return "shippingbox"
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
    ] + outdoorCatalog

    static let sunChoices = ["full sun", "part sun", "shade"]

    /// Details every built outdoor feature can carry: when it went in, what it's made of, who to call.
    /// A template's own `material` choice wins over the free-text one.
    static let commonOutdoorFields: [Field] = [
        Field("yearInstalled", "Year installed", .number), Field("material", "Material", .text), serviceContactField]
    static let serviceContactField = Field("serviceContact", "Service contact", .text)

    /// Appends the `extra` fields the template doesn't already define (by key).
    static func outdoor(_ t: ThingTemplate, adding extra: [Field] = commonOutdoorFields) -> ThingTemplate {
        var t = t
        let keys = Set(t.fields.map(\.key))
        t.fields += extra.filter { !keys.contains($0.key) }
        return t
    }

    /// Yard, garden and outdoor living (the Outside level).
    static let outdoorCatalog: [ThingTemplate] = plantCatalog.map { outdoor($0, adding: [serviceContactField]) }
        + featureCatalog.map { outdoor($0) }
        + [outdoor(lawnMower, adding: [serviceContactField])]

    static let plantCatalog: [ThingTemplate] = [
        ThingTemplate(key: "tree", name: "Tree", category: .outdoor, symbol: "tree", fields: [
            Field("species", "Species", .text), Field("plantedDate", "Planted", .date), Field("heightFt", "Approx. height (ft)", .number)],
                      suggestedChore: SuggestedChore(title: "Prune tree", rule: RepeatRule(freq: .monthly, interval: 12))),
        ThingTemplate(key: "shrub", name: "Bush / shrub", category: .outdoor, symbol: "leaf", fields: [
            Field("species", "Species", .text), Field("plantedDate", "Planted", .date), Field("sun", "Sun", .choice, choices: sunChoices)],
                      suggestedChore: SuggestedChore(title: "Trim bushes", rule: RepeatRule(freq: .monthly, interval: 6))),
        ThingTemplate(key: "flower_bed", name: "Flowers / flower bed", category: .outdoor, symbol: "camera.macro", fields: [
            Field("plants", "Plants", .text), Field("lifecycle", "Type", .choice, choices: ["perennial", "annual", "mixed"]),
            Field("bloomSeason", "Bloom season", .choice, choices: ["spring", "summer", "fall", "winter"]),
            Field("sun", "Sun", .choice, choices: sunChoices)]),
        ThingTemplate(key: "hedge", name: "Hedge", category: .outdoor, symbol: "leaf.fill", fields: [
            Field("species", "Species", .text), Field("lengthFt", "Length (ft)", .number)],
                      suggestedChore: SuggestedChore(title: "Trim hedge", rule: RepeatRule(freq: .monthly, interval: 3))),
        ThingTemplate(key: "vegetable_garden", name: "Vegetable garden", category: .outdoor, symbol: "carrot", fields: [
            Field("crops", "Crops", .text), Field("raisedBed", "Raised bed", .bool), Field("sun", "Sun", .choice, choices: sunChoices)]),
    ]

    static let featureCatalog: [ThingTemplate] = [
        ThingTemplate(key: "fence", name: "Fence / gate", category: .outdoor, symbol: "rectangle.split.3x1", fields: [
            Field("material", "Material", .choice, choices: ["wood", "vinyl", "chain link", "metal", "aluminum", "wrought iron", "composite"]),
            Field("lengthFt", "Length (ft)", .number), Field("heightFt", "Height (ft)", .number)],
                      aliases: ["gate", "railing", "privacy"]),
        ThingTemplate(key: "playset", name: "Swing set / playset", category: .outdoor, symbol: "figure.play", fields: [
            Field("material", "Material", .choice, choices: ["wood", "metal", "plastic", "vinyl"])],
                      suggestedChore: SuggestedChore(title: "Inspect playset", rule: RepeatRule(freq: .monthly, interval: 12)),
                      aliases: ["swingset", "play structure", "jungle gym", "slide"]),
        ThingTemplate(key: "patio", name: "Patio", category: .outdoor, symbol: "square.grid.3x3.fill", fields: [
            Field("surface", "Surface", .choice, choices: ["concrete", "pavers", "stone", "brick", "gravel"]),
            Field("areaSqFt", "Area (sq ft)", .number)]),
        ThingTemplate(key: "deck", name: "Deck", category: .outdoor, symbol: "square.split.1x2", fields: [
            Field("material", "Material", .choice, choices: ["wood", "composite", "PVC"]), Field("areaSqFt", "Area (sq ft)", .number),
            Field("stainColor", "Stain / color", .text)],
                      suggestedChore: SuggestedChore(title: "Seal deck", rule: RepeatRule(freq: .monthly, interval: 24))),
        ThingTemplate(key: "fire_pit", name: "Fire pit", category: .outdoor, symbol: "flame.fill", fields: [
            Field("fuel", "Fuel", .choice, choices: ["wood", "propane", "natural gas"])]),
        ThingTemplate(key: "shed", name: "Shed", category: .outdoor, symbol: "house.lodge", fields: [
            Field("material", "Material", .choice, choices: ["wood", "metal", "resin"]), Field("power", "Has power", .bool)]),
        ThingTemplate(key: "pool", name: "Pool", category: .outdoor, symbol: "figure.pool.swim", fields: [
            Field("type", "Type", .choice, choices: ["in-ground", "above-ground"]), Field("gallons", "Volume (gal)", .number),
            Field("heated", "Heated", .bool), Field("sanitizer", "Sanitizer", .choice, choices: ["chlorine", "salt", "other"])],
                      suggestedChore: SuggestedChore(title: "Test pool water", rule: RepeatRule(freq: .weekly, interval: 1))),
        ThingTemplate(key: "hot_tub", name: "Hot tub", category: .outdoor, symbol: "bubbles.and.sparkles", fields: [
            Field("gallons", "Volume (gal)", .number), Field("filterModel", "Filter model", .text)],
                      suggestedChore: SuggestedChore(title: "Clean hot tub filter", rule: RepeatRule(freq: .monthly, interval: 1)),
                      aliases: ["spa", "jacuzzi"]),
        ThingTemplate(key: "grill", name: "Grill", category: .outdoor, symbol: "frying.pan", fields: [
            Field("fuel", "Fuel", .choice, choices: ["propane", "natural gas", "charcoal", "pellet", "electric"])],
                      suggestedChore: SuggestedChore(title: "Deep clean grill", rule: RepeatRule(freq: .monthly, interval: 6)),
                      aliases: ["bbq", "barbecue", "smoker"]),
        ThingTemplate(key: "outdoor_furniture", name: "Outdoor furniture", category: .outdoor, symbol: "chair.lounge", fields: [
            Field("material", "Material", .choice, choices: ["wood", "metal", "wicker", "plastic"]), Field("hasCushions", "Cushions", .bool)]),
        ThingTemplate(key: "pergola", name: "Pergola / gazebo", category: .outdoor, symbol: "tent", fields: [
            Field("material", "Material", .choice, choices: ["wood", "vinyl", "aluminum", "steel"])]),
        ThingTemplate(key: "sprinkler_system", name: "Sprinkler / irrigation", category: .outdoor, symbol: "sprinkler.and.droplets", fields: [
            Field("zones", "Zones", .number), Field("controller", "Controller", .text)],
                      suggestedChore: SuggestedChore(title: "Winterize sprinklers", rule: RepeatRule(freq: .monthly, interval: 12)),
                      aliases: ["irrigation", "drip", "lawn watering"]),
        ThingTemplate(key: "outdoor_lighting", name: "Outdoor lighting", category: .outdoor, symbol: "lamp.floor", fields: [
            Field("type", "Type", .choice, choices: ["path", "flood", "string", "wall", "landscape"]),
            Field("power", "Power", .choice, choices: ["hardwired", "low voltage", "solar", "plug-in"]),
            Field("bulbBase", "Bulb base", .choice, choices: ["E26", "E12", "GU10", "MR16", "integrated LED", "other"]),
            Field("timer", "Timer / sensor", .bool)]),
        // Utility lines and septic.
        ThingTemplate(key: "power_line", name: "Power line", category: .outdoor, symbol: "bolt.horizontal", fields: [
            Field("route", "Route", .choice, choices: ["overhead", "buried"]), Field("provider", "Utility provider", .text),
            Field("meterLocation", "Meter location", .text), Field("amps", "Service (amps)", .number)],
                      aliases: ["electric", "electrical service", "utility", "meter", "overhead", "underground"]),
        ThingTemplate(key: "gas_line", name: "Gas line", category: .outdoor, symbol: "flame.circle", fields: [
            Field("gasType", "Gas", .choice, choices: ["natural gas", "propane"]), Field("provider", "Utility provider", .text),
            Field("meterLocation", "Meter / tank location", .text), Field("shutoffLocation", "Shutoff location", .text),
            Field("material", "Material", .choice, choices: ["black iron", "CSST", "polyethylene", "copper", "other"])],
                      aliases: ["natural gas", "propane", "utility", "meter", "shutoff"]),
        ThingTemplate(key: "water_line", name: "Water line", category: .outdoor, symbol: "drop.circle", fields: [
            Field("source", "Source", .choice, choices: ["city", "well"]), Field("provider", "Utility provider", .text),
            Field("shutoffLocation", "Shutoff location", .text),
            Field("material", "Material", .choice, choices: ["copper", "PEX", "PVC", "galvanized", "polyethylene", "other"])],
                      aliases: ["water main", "service line", "well", "utility", "shutoff"]),
        ThingTemplate(key: "sewer_line", name: "Sewer line", category: .outdoor, symbol: "arrow.down.to.line", fields: [
            Field("connection", "Connects to", .choice, choices: ["city sewer", "septic"]),
            Field("cleanoutLocation", "Cleanout location", .text), Field("lastInspected", "Last camera inspection", .date),
            Field("material", "Material", .choice, choices: ["PVC", "ABS", "cast iron", "clay", "Orangeburg", "other"])],
                      aliases: ["sewerage", "sewage", "main drain", "drain line", "cleanout", "utility"]),
        ThingTemplate(key: "septic_tank", name: "Septic tank", category: .outdoor, symbol: "cylinder", fields: [
            Field("tankSizeGal", "Tank size (gal)", .number), Field("lastPumped", "Last pumped", .date),
            Field("tankLocation", "Tank / lid location", .text), Field("drainField", "Drain field location", .text),
            Field("material", "Material", .choice, choices: ["concrete", "fiberglass", "plastic", "steel"])],
                      suggestedChore: SuggestedChore(title: "Pump septic tank", rule: RepeatRule(freq: .monthly, interval: 36)),
                      aliases: ["septic system", "leach field", "drain field", "sewage", "sewerage"]),
    ]

    static let lawnMower = ThingTemplate(key: "lawn_mower", name: "Lawn mower", category: .outdoor, symbol: "leaf.arrow.triangle.circlepath", fields: [
        Field("type", "Type", .choice, choices: ["push", "self-propelled", "riding", "robotic"]),
        Field("fuel", "Fuel", .choice, choices: ["gas", "battery", "corded"])],
        suggestedChore: SuggestedChore(title: "Service lawn mower", rule: RepeatRule(freq: .monthly, interval: 12)))
}

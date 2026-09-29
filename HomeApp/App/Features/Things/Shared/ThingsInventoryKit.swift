import Foundation
import HomeCore

/// Pure (SwiftUI-free) helpers shared by the Things, Measurements, Inventory, Search, People and Settings features.
/// Everything lives under the `TIK` namespace so it cannot collide with types other feature folders add to the
/// same app module. No UI, no I/O: these are plain value transformations over HomeCore types.
enum TIK {}

// MARK: - Length entry (spec 07 FR-MSR-03)

extension TIK {
    /// How W/D/H fields are typed: plain inches, feet + inches (two boxes) or centimeters.
    enum LengthMode: String, CaseIterable, Hashable, Identifiable {
        case inches, feetInches, centimeters
        var id: String { rawValue }
        var title: String {
            switch self {
            case .inches: return "in"
            case .feetInches: return "ft + in"
            case .centimeters: return "cm"
            }
        }
        static func preferred(for system: UnitSystem) -> LengthMode { system == .metric ? .centimeters : .inches }
    }

    enum LengthInput {
        static let cmPerInch = 2.54

        /// Unicode vulgar fractions accepted in typed lengths ("35¾").
        static let unicodeFractions: [Character: String] = [
            "¼": "1/4", "½": "1/2", "¾": "3/4", "⅛": "1/8", "⅜": "3/8", "⅝": "5/8", "⅞": "7/8",
            "⅓": "1/3", "⅔": "2/3", "⅙": "1/6", "⅚": "5/6", "⅕": "1/5",
        ]

        /// Rewrites fractions as decimals so `HomeLengthFormatter.parse` can read them:
        /// `35 3/4` → `35.75`, `35¾` → `35.75`, `2'8½"` → `2'8.5"`, `3/4` → `0.75`.
        static func normalizeFractions(_ text: String) -> String {
            var expanded = ""
            for ch in text {
                if let f = unicodeFractions[ch] { expanded += " " + f } else { expanded.append(ch) }
            }
            var out: [String] = []
            for token in expanded.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) {
                guard let (value, suffix) = leadingFraction(token) else { out.append(token); continue }
                if let prev = out.last, let (prefix, number) = trailingNumber(prev) {
                    out[out.count - 1] = prefix + decimalString(number + value) + suffix
                } else {
                    out.append(decimalString(value) + suffix)
                }
            }
            return out.joined(separator: " ")
        }

        /// `"3/4\""` → (0.75, "\""). nil when the token doesn't start with `<digits>/<digits>`.
        static func leadingFraction(_ token: String) -> (Double, String)? {
            let chars = Array(token)
            var i = 0
            var num = ""
            while i < chars.count, chars[i].isASCII, chars[i].isNumber { num.append(chars[i]); i += 1 }
            guard !num.isEmpty, i < chars.count, chars[i] == "/" else { return nil }
            i += 1
            var den = ""
            while i < chars.count, chars[i].isASCII, chars[i].isNumber { den.append(chars[i]); i += 1 }
            guard let n = Double(num), let d = Double(den), d > 0 else { return nil }
            return (n / d, String(chars[i...]))
        }

        /// `"2'8"` → ("2'", 8); `"35"` → ("", 35); nil when the token doesn't end in a plain number.
        static func trailingNumber(_ token: String) -> (String, Double)? {
            let chars = Array(token)
            var i = chars.count
            while i > 0, chars[i - 1].isASCII, chars[i - 1].isNumber || chars[i - 1] == "." { i -= 1 }
            guard i < chars.count, let v = Double(String(chars[i...])) else { return nil }
            return (String(chars[..<i]), v)
        }

        static func decimalString(_ v: Double) -> String {
            let r = (v * 10_000).rounded() / 10_000
            if r == r.rounded() { return String(Int(r)) }
            return String(r)
        }

        /// Parses one typed length into inches (> 0, rounded to 2 decimals). Bare numbers are inches, or cm in
        /// `.centimeters` mode. Units typed explicitly (`2'8"`, `81.3cm`, `0.81m`) always win.
        static func parse(_ text: String, mode: LengthMode) -> Double? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let normalized = normalizeFractions(trimmed)
            let bare: UnitSystem = mode == .centimeters ? .metric : .imperial
            guard let v = HomeLengthFormatter.parse(normalized, bareUnit: bare) else { return nil }
            return validated(v)
        }

        /// Feet + inches boxes (either may be empty, not both).
        static func parse(feet: String, inches: String) -> Double? {
            let f = feet.trimmingCharacters(in: .whitespaces), i = inches.trimmingCharacters(in: .whitespaces)
            guard !(f.isEmpty && i.isEmpty) else { return nil }
            var total = 0.0
            if !f.isEmpty {
                guard let fv = number(f) else { return nil }
                total += fv * 12
            }
            if !i.isEmpty {
                guard let iv = parse(i, mode: .inches) ?? number(i) else { return nil }
                total += iv
            }
            return validated(total)
        }

        /// A plain number that may contain a fraction ("2 1/2", "2½").
        static func number(_ text: String) -> Double? {
            Double(normalizeFractions(text.trimmingCharacters(in: .whitespaces)))
        }

        static func validated(_ v: Double) -> Double? {
            guard v.isFinite, v > 0 else { return nil }
            return (v * 100).rounded() / 100
        }

        /// Field text for a stored value: `.inches` → "35¾" (eighths) or "35.6"; `.centimeters` → "90.8";
        /// `.feetInches` → ("2", "8½"). Second element is only used by `.feetInches`.
        static func fieldTexts(_ inches: Double?, mode: LengthMode) -> (String, String) {
            guard let v = inches, v.isFinite else { return ("", "") }
            switch mode {
            case .inches: return (inchText(v), "")
            case .centimeters: return (decimalString((v * cmPerInch * 10).rounded() / 10), "")
            case .feetInches:
                let feet = Int((v / 12).rounded(.down))
                let rest = v - Double(feet) * 12
                return (feet == 0 ? "" : String(feet), rest < 0.005 ? "0" : inchText(rest))
            }
        }

        /// "35¾" when the value is a whole number of eighths, else up to 2 decimals.
        static func inchText(_ v: Double) -> String {
            let eighths = v * 8
            if abs(eighths - eighths.rounded()) < 0.001 {
                let e = Int(eighths.rounded())
                let whole = e / 8, frac = e % 8
                let glyph = ["", "⅛", "¼", "⅜", "½", "⅝", "¾", "⅞"][frac]
                return whole == 0 && !glyph.isEmpty ? glyph : "\(whole)\(glyph)"
            }
            return decimalString((v * 100).rounded() / 100)
        }
    }
}

// MARK: - Places (scope labels and pickers)

extension TIK {
    /// Levels + spaces of the property, for scope labels and "where" pickers.
    struct PlaceIndex: Hashable {
        var levels: [Level]
        var spaces: [Space]

        init(levels: [Level] = [], spaces: [Space] = []) {
            self.levels = levels.filter { $0.deletedAt == nil }.sortedForPills
            self.spaces = spaces.filter { $0.deletedAt == nil }
        }

        func level(_ id: UUID?) -> Level? { id.flatMap { i in levels.first { $0.id == i } } }
        func space(_ id: UUID?) -> Space? { id.flatMap { i in spaces.first { $0.id == i } } }

        /// Rooms/zones of a level, sorted by name.
        func spaces(on levelId: UUID) -> [Space] {
            spaces.filter { $0.levelId == levelId }.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
        }

        /// "Kitchen · 1st Floor", "1st Floor · whole floor", "Whole house".
        func label(for scope: Scope) -> String {
            switch scope {
            case .space(let s, let l):
                let room = space(s)?.name ?? "Room"
                return [room, level(l)?.name].compactMap { $0 }.joined(separator: " · ")
            case .level(let l): return "\(level(l)?.name ?? "Floor") · whole floor"
            case .property: return "Whole house"
            }
        }

        /// Scope for a room id (nil when unknown).
        func scope(forSpace id: UUID) -> Scope? { space(id).map { .space($0.id, level: $0.levelId) } }
    }
}

// MARK: - Templates (spec 06)

extension TIK {
    /// Extra per-template data from `server/data/templates.json` that the HomeCore catalog doesn't carry
    /// (default names, units, spare-stock naming). Keys follow the HomeCore catalog field keys.
    struct TemplateExtra: Hashable {
        var defaultName: String? = nil
        var fieldUnits: [String: String] = [:]
        var integerFields: Set<String> = []
        var spareNameFormat: String? = nil
        var spareUnit: String = "ea"
        var spareLowThreshold: Double = 1
    }

    static let templateExtras: [String: TemplateExtra] = [
        "light_fixture": TemplateExtra(defaultName: "Light fixture", fieldUnits: ["wattage": "W"], integerFields: ["bulbCount"],
                                       spareNameFormat: "{bulbBase} bulb"),
        "hvac_furnace": TemplateExtra(defaultName: "Furnace", integerFields: ["merv"],
                                      spareNameFormat: "Furnace filter {filterSize} MERV {merv}"),
        "hvac_filter": TemplateExtra(defaultName: "Return air filter", integerFields: ["merv"],
                                     spareNameFormat: "Air filter {filterSize} MERV {merv}"),
        "water_heater": TemplateExtra(defaultName: "Water heater", fieldUnits: ["capacityGal": "gal"]),
        "water_filter": TemplateExtra(defaultName: "Water filter", spareNameFormat: "Water filter {filterModel}"),
        "fridge_water_filter": TemplateExtra(defaultName: "Fridge water filter", spareNameFormat: "Fridge filter {filterModel}"),
        "smoke_detector": TemplateExtra(defaultName: "Smoke detector"),
        "refrigerator": TemplateExtra(defaultName: "Fridge"),
        "washer": TemplateExtra(defaultName: "Washing machine"),
        "tv": TemplateExtra(defaultName: "TV", fieldUnits: ["screenSize": "in"], integerFields: ["screenSize"]),
    ]

    static func extra(for templateKey: String?) -> TemplateExtra {
        templateKey.flatMap { templateExtras[$0] } ?? TemplateExtra()
    }

    static func defaultName(for template: ThingTemplate) -> String {
        extra(for: template.key).defaultName ?? template.name
    }

    /// Catalog grouped by category (picker sections), categories in a fixed order.
    static func templatesByCategory(_ catalog: [ThingTemplate] = ThingTemplate.catalog) -> [(Thing.Category, [ThingTemplate])] {
        let order: [Thing.Category] = [.appliance, .electronic, .furniture, .fixture, .system]
        return order.compactMap { c in
            let t = catalog.filter { $0.category == c }
            return t.isEmpty ? nil : (c, t)
        }
    }

    static func categoryTitle(_ c: Thing.Category) -> String {
        switch c {
        case .appliance: return "Appliance"; case .electronic: return "Electronic"; case .furniture: return "Furniture"
        case .fixture: return "Fixture"; case .system: return "System"; case .unknown: return "Other"
        }
    }

    /// Template attribute text for a field (the value shown in a text box).
    static func attributeText(_ value: JSONValue?, kind: ThingTemplate.Field.Kind) -> String {
        guard let value else { return "" }
        switch kind {
        case .bool: return ""
        default: return value.displayText
        }
    }

    /// Parses a text box back into a JSON attribute. Empty → nil (removes the key). Numbers that don't parse are
    /// kept as text so nothing typed is lost.
    static func attributeValue(fromText text: String, kind: ThingTemplate.Field.Kind) -> JSONValue? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        switch kind {
        case .number:
            if let d = Double(t.replacingOccurrences(of: ",", with: ".")) { return .number(d) }
            return .string(t)
        case .date:
            return LocalDate(string: t).map { .string($0.description) } ?? .string(t)
        default:
            return .string(t)
        }
    }

    /// Spare-stock name (FR-THG-20): "Furnace filter 16x25x1 MERV 11". Placeholders without a value are dropped,
    /// together with an ALL-CAPS label word right before them ("MERV"). Falls back to "<thing name> spare".
    static func spareName(templateKey: String?, attributes: [String: JSONValue], thingName: String) -> String {
        guard let format = extra(for: templateKey).spareNameFormat else { return "\(thingName) spare" }
        var kept: [String] = []
        var keptIsLabel: [Bool] = []
        var usedPlaceholder = false
        for word in format.split(separator: " ").map(String.init) {
            if let open = word.firstIndex(of: "{"), let close = word.firstIndex(of: "}"), open < close {
                let key = String(word[word.index(after: open)..<close])
                let value = attributes[key]?.displayText.trimmingCharacters(in: .whitespaces) ?? ""
                if value.isEmpty {
                    if keptIsLabel.last == true { kept.removeLast(); keptIsLabel.removeLast() }
                    continue
                }
                usedPlaceholder = true
                kept.append(word.replacingCharacters(in: open...close, with: value))
                keptIsLabel.append(false)
            } else {
                kept.append(word)
                keptIsLabel.append(word.count > 1 && word == word.uppercased() && word.contains(where: \.isLetter))
            }
        }
        guard usedPlaceholder else { return "\(thingName) spare" }
        return kept.joined(separator: " ")
    }

    /// Warranty badge (FR-THG-33). `warn` = ends within 60 days.
    struct WarrantyBadge: Hashable {
        enum Tone: Hashable { case ok, warn, expired }
        var text: String
        var tone: Tone
    }

    static let monthAbbrev = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static func warrantyBadge(end: LocalDate?, today: LocalDate) -> WarrantyBadge? {
        guard let end else { return nil }
        let days = today.days(until: end)
        if days < 0 { return WarrantyBadge(text: "Warranty expired", tone: .expired) }
        if days <= 60 { return WarrantyBadge(text: days == 0 ? "Warranty ends today" : "Warranty ends in \(days) day\(days == 1 ? "" : "s")", tone: .warn) }
        return WarrantyBadge(text: "Under warranty until \(monthAbbrev[end.month - 1]) \(end.year)", tone: .ok)
    }

    static func moneyText(_ m: Money?) -> String {
        guard let m else { return "" }
        return m.plainString.hasSuffix(".00") ? String(m.plainString.dropLast(3)) : m.plainString
    }

    /// "$1,299.99" / "1299.99" → Money. Empty or unparseable → nil.
    static func money(fromText text: String, currency: String) -> Money? {
        let cleaned = text.filter { $0.isNumber || $0 == "." || $0 == "-" }
        guard !cleaned.isEmpty, let d = Decimal(string: cleaned) else { return nil }
        return Money(major: d, currency: currency)
    }
}

// MARK: - Form state (value types the forms edit; conversion to/from HomeCore models)

extension TIK {
    struct ThingFormState: Hashable {
        var name = ""
        var category: Thing.Category = .appliance
        var ownership: Thing.Ownership = .owned
        var templateKey: String?
        var attributes: [String: JSONValue] = [:]
        var brand = ""
        var model = ""
        var serial = ""
        var purchaseDate: LocalDate?
        var priceText = ""
        var warrantyEnd: LocalDate?
        var dims = Dims3.empty
        var fitMeasurementId: UUID?
        var notes = ""
        var scope: Scope = .property

        init() {}

        init(thing t: Thing) {
            name = t.name; category = t.category == .unknown ? .appliance : t.category
            ownership = t.ownership == .unknown ? .owned : t.ownership
            templateKey = t.templateKey; attributes = t.attributes
            brand = t.brand ?? ""; model = t.model ?? ""; serial = t.serial ?? ""
            purchaseDate = t.purchaseDate; priceText = TIK.moneyText(t.purchasePrice); warrantyEnd = t.warrantyEnd
            dims = t.dims; fitMeasurementId = t.fitMeasurementId; notes = t.notes ?? ""; scope = t.scope
        }

        var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
        var canSave: Bool { !trimmedName.isEmpty }
        var template: ThingTemplate? { templateKey.flatMap(ThingTemplate.find) }

        /// Choosing a template sets category, default name (if the name is empty or was the previous default)
        /// and keeps only attributes the new template knows (FR-THG-10).
        mutating func apply(template: ThingTemplate?) {
            let previousDefault = self.template.map(TIK.defaultName(for:))
            templateKey = template?.key
            guard let template else { return }
            category = template.category
            if trimmedName.isEmpty || trimmedName == previousDefault { name = TIK.defaultName(for: template) }
            let keys = Set(template.fields.map(\.key))
            attributes = attributes.filter { keys.contains($0.key) }
        }

        func policy() -> FitPolicy { FitPolicy.default(templateKey: templateKey, category: category) }

        static func nonEmpty(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }

        func draft(propertyId: UUID, currency: String) -> ThingDraft {
            ThingDraft(propertyId: propertyId, scope: scope, category: category, name: trimmedName, ownership: ownership,
                       templateKey: templateKey, attributes: attributes, brand: Self.nonEmpty(brand), model: Self.nonEmpty(model),
                       serial: Self.nonEmpty(serial), purchaseDate: purchaseDate,
                       purchasePrice: TIK.money(fromText: priceText, currency: currency), warrantyEnd: warrantyEnd,
                       dims: dims, fitMeasurementId: fitMeasurementId, notes: Self.nonEmpty(notes))
        }

        func applied(to t: Thing, currency: String) -> Thing {
            var out = t
            out.name = trimmedName; out.category = category; out.ownership = ownership; out.templateKey = templateKey
            out.attributes = attributes; out.brand = Self.nonEmpty(brand); out.model = Self.nonEmpty(model)
            out.serial = Self.nonEmpty(serial); out.purchaseDate = purchaseDate
            out.purchasePrice = TIK.money(fromText: priceText, currency: t.purchasePrice?.currency ?? currency)
            out.warrantyEnd = warrantyEnd; out.dims = dims; out.fitMeasurementId = fitMeasurementId
            out.notes = Self.nonEmpty(notes)
            if out.scope != scope { out.scope = scope; out.pin = nil }  // pin coordinates belong to the old room
            return out
        }
    }

    struct MeasurementFormState: Hashable {
        var label = ""
        var kind: HomeMeasurement.Kind = .opening
        var spaceId: UUID?
        var openingId: UUID?
        var storageSpotId: UUID?
        var dims = Dims3.empty
        var isDeliveryPath = false
        var note = ""

        init() {}
        init(measurement m: HomeMeasurement) {
            label = m.label; kind = m.kind == .unknown ? .general : m.kind; spaceId = m.spaceId; openingId = m.openingId
            storageSpotId = m.storageSpotId; dims = m.dims; isDeliveryPath = m.isDeliveryPath; note = m.note ?? ""
        }

        var trimmedLabel: String { label.trimmingCharacters(in: .whitespacesAndNewlines) }
        var hasDimension: Bool { !dims.isEmpty && dims.known.allSatisfy { $0 > 0 } }
        var hasAnchor: Bool { spaceId != nil || openingId != nil }
        /// Validation message, nil when saveable (AC-MSR-8).
        var problem: String? {
            if trimmedLabel.isEmpty { return "Enter a name" }
            if !hasAnchor { return "Choose a room" }
            if !hasDimension { return "Enter at least one dimension" }
            return nil
        }
        /// Delivery path only applies to doors (FR-MSR-01).
        var effectiveDeliveryPath: Bool { kind == .door && isDeliveryPath }

        /// Zone area in sq in when width and depth are both set (FR-MSR-07).
        var zoneAreaSqIn: Double? {
            guard kind == .zone, let w = dims.width, let d = dims.depth else { return nil }
            return w * d
        }

        func input(propertyId: UUID) -> MeasurementInput {
            MeasurementInput(propertyId: propertyId, label: trimmedLabel, kind: kind, spaceId: spaceId, openingId: openingId,
                             storageSpotId: storageSpotId, dims: dims, isDeliveryPath: effectiveDeliveryPath,
                             note: ThingFormState.nonEmpty(note))
        }

        func applied(to m: HomeMeasurement) -> HomeMeasurement {
            var out = m
            out.label = trimmedLabel; out.kind = kind; out.spaceId = spaceId; out.openingId = openingId
            out.storageSpotId = storageSpotId; out.dims = dims; out.isDeliveryPath = effectiveDeliveryPath
            out.note = ThingFormState.nonEmpty(note)
            return out
        }
    }

    struct InventoryFormState: Hashable {
        var kind: InventoryItem.Kind = .pantry
        var name = ""
        var category = ""
        var ownerId: UUID?
        var scope: Scope = .property
        var storageSpotId: UUID?
        var quantity: Double = 1
        var unit = "ea"
        var season: Season?
        var inRotation = true
        var expiresOn: LocalDate?
        var isLow = false
        var lowThresholdText = ""
        var linkedThingId: UUID?
        var notes = ""

        init() {}
        init(item i: InventoryItem) {
            kind = i.kind == .unknown ? .other : i.kind; name = i.name; category = i.category ?? ""; ownerId = i.ownerId
            scope = i.scope; storageSpotId = i.storageSpotId; quantity = i.quantity; unit = i.unit ?? "ea"
            season = i.season == .unknown ? nil : i.season; inRotation = i.inRotation ?? true; expiresOn = i.expiresOn
            isLow = i.isLow; lowThresholdText = i.lowThreshold.map(TIK.quantityText) ?? ""; linkedThingId = i.linkedThingId
            notes = i.notes ?? ""
        }

        var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
        var canSave: Bool { !trimmedName.isEmpty && quantity >= 0 }
        var lowThreshold: Double? { Double(lowThresholdText.replacingOccurrences(of: ",", with: ".")).map { max(0, $0) } }
        /// Season/rotation only apply to clothing (FR-INV-30); stored items can carry a season too (Q-4) but the
        /// swap screen only lists clothing.
        var seasonApplies: Bool { kind == .clothing || kind == .stored }

        func draft(propertyId: UUID) -> InventoryDraft {
            InventoryDraft(propertyId: propertyId, kind: kind, name: trimmedName, category: ThingFormState.nonEmpty(category),
                           ownerId: ownerId, scope: scope, storageSpotId: storageSpotId, quantity: max(0, quantity),
                           unit: ThingFormState.nonEmpty(unit), season: seasonApplies ? season : nil,
                           inRotation: kind == .clothing ? inRotation : nil, expiresOn: kind == .pantry ? expiresOn : nil,
                           isLow: isLow, lowThreshold: lowThreshold, linkedThingId: linkedThingId,
                           notes: ThingFormState.nonEmpty(notes))
        }

        func applied(to i: InventoryItem) -> InventoryItem {
            let d = draft(propertyId: i.propertyId)
            var out = i
            out.kind = d.kind; out.name = d.name; out.category = d.category; out.ownerId = d.ownerId; out.scope = d.scope
            out.storageSpotId = d.storageSpotId; out.quantity = d.quantity; out.unit = d.unit; out.season = d.season
            out.inRotation = d.inRotation; out.expiresOn = d.expiresOn; out.isLow = d.isLow; out.lowThreshold = d.lowThreshold
            out.linkedThingId = d.linkedThingId; out.notes = d.notes
            return InventoryLogic.applyLowThreshold(out)
        }

        /// "Add another" (FR-INV-22): keep kind, owner, location (and season/state); clear the rest.
        func nextEntry() -> InventoryFormState {
            var n = InventoryFormState()
            n.kind = kind; n.ownerId = ownerId; n.scope = scope; n.storageSpotId = storageSpotId; n.unit = unit
            n.season = season; n.inRotation = inRotation; n.category = category
            return n
        }
    }
}

// MARK: - Inventory helpers (spec 08)

extension TIK {
    static let inventoryUnits = ["ea", "pair", "lb", "oz", "can", "box", "bag", "bottle"]

    static func categorySuggestions(for kind: InventoryItem.Kind) -> [String] {
        switch kind {
        case .pantry: return ["canned", "spices", "baking", "grains", "snacks", "drinks", "condiments", "frozen"]
        case .clothing: return ["coat", "boots", "sweaters", "shirts", "pants", "shorts", "swimwear", "shoes", "accessories"]
        case .stored: return ["decor", "filters", "bulbs", "tools", "luggage", "camping", "documents"]
        case .other, .unknown: return []
        }
    }

    static func kindTitle(_ k: InventoryItem.Kind) -> String {
        switch k {
        case .pantry: return "Pantry"; case .clothing: return "Clothing"; case .stored: return "Stored"
        case .other, .unknown: return "Other"
        }
    }

    static func seasonTitle(_ s: Season?) -> String {
        switch s {
        case .summer?: return "Summer"; case .winter?: return "Winter"; case .allYear?: return "All-year"
        default: return "None"
        }
    }

    /// "2", "1.5", "0.25".
    static func quantityText(_ q: Double) -> String { LengthInput.decimalString((q * 100).rounded() / 100) }

    /// "2 lb", "3" (unit "ea" omitted).
    static func quantityLabel(_ q: Double?, unit: String?) -> String {
        guard let q else { return "" }
        let u = (unit ?? "").trimmingCharacters(in: .whitespaces)
        return u.isEmpty || u == "ea" ? quantityText(q) : "\(quantityText(q)) \(u)"
    }

    /// Expiry badge tone (FR-INV-42): red expired, amber ≤ 7 days.
    enum ExpiryTone: Hashable { case expired, soon, none }
    static func expiryTone(_ expiresOn: LocalDate?, today: LocalDate) -> ExpiryTone {
        guard let e = expiresOn else { return .none }
        if e < today { return .expired }
        return today.days(until: e) <= 7 ? .soon : .none
    }

    /// Depth-first flattening of a spot tree (pickers with indentation).
    static func flatten(_ nodes: [SpotNode]) -> [SpotNode] {
        nodes.flatMap { [$0] + flatten($0.children) }
    }

    /// Spots a spot may move under (same room, not itself or a descendant) — FR-INV-13.
    static func validParents(for spotId: UUID, in nodes: [SpotNode]) -> [SpotNode] {
        let all = flatten(nodes)
        let spots = all.map(\.spot)
        let excluded = Set(InventoryLogic.subtree(of: spotId, in: spots))
        return all.filter { !excluded.contains($0.id) }
    }

    /// Default quantity after "Bought" (FR-INV-51): back above the threshold, else +1.
    static func boughtQuantity(current: Double, threshold: Double?) -> Double {
        if let t = threshold { return max(current + 1, t + 1) }
        return current + 1
    }

    /// Seasonal swap groups (FR-INV-31): owner → location, keeping the repository's order.
    struct SwapGroup: Hashable, Identifiable {
        var owner: String?
        var location: String
        var lines: [SwapLine]
        var id: String { (owner ?? "") + "|" + location }
    }

    static func swapGroups(_ lines: [SwapLine], ownerFilter: String?) -> [SwapGroup] {
        var groups: [SwapGroup] = []
        for line in lines {
            if let f = ownerFilter, line.owner != f { continue }
            let loc = [line.room, line.spotPath].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " › ")
            let location = loc.isEmpty ? "No location" : loc
            if let idx = groups.firstIndex(where: { $0.owner == line.owner && $0.location == location }) {
                groups[idx].lines.append(line)
            } else {
                groups.append(SwapGroup(owner: line.owner, location: location, lines: [line]))
            }
        }
        return groups
    }

    /// Shopping list partition: replacements (filters & bulbs) first, then low items (FR-INV-50).
    enum ShoppingFilter: String, CaseIterable, Hashable, Identifiable {
        case all, pantry, filtersAndBulbs
        var id: String { rawValue }
        var title: String {
            switch self { case .all: return "All"; case .pantry: return "Running low"; case .filtersAndBulbs: return "Filters & bulbs" }
        }
        func includes(_ line: ShoppingLine) -> Bool {
            switch self {
            case .all: return true
            case .pantry: return line.reason == .low
            case .filtersAndBulbs: return line.reason == .replacementDue
            }
        }
    }

    /// Plain-text list for the share sheet (FR-INV-52).
    static func shoppingText(_ lines: [ShoppingLine]) -> String {
        let due = lines.filter { $0.reason == .replacementDue }
        let low = lines.filter { $0.reason == .low }
        var out = ["Shopping list"]
        if !due.isEmpty {
            out.append("")
            out.append("Filters & bulbs")
            out += due.map { "• " + $0.label }
        }
        if !low.isEmpty {
            out.append("")
            out.append("Running low")
            out += low.map { l in
                let q = quantityLabel(l.quantity, unit: l.unit)
                return "• " + l.label + (q.isEmpty ? "" : " (\(q) left)")
            }
        }
        if due.isEmpty && low.isEmpty { out.append("You're stocked up.") }
        return out.joined(separator: "\n")
    }
}

// MARK: - Search (spec 09 / LLD §12)

extension TIK {
    /// Hits grouped by entity type; groups ordered by their best-ranked hit, hits keep rank order.
    static func groupedHits(_ hits: [SearchHit]) -> [(SearchEntityType, [SearchHit])] {
        var order: [SearchEntityType] = []
        var buckets: [SearchEntityType: [SearchHit]] = [:]
        for h in hits {
            if buckets[h.entityType] == nil { order.append(h.entityType) }
            buckets[h.entityType, default: []].append(h)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    /// The "where is" card applies only when the *top* hit qualifies (FR-SES-05).
    static func whereIsHit(_ hits: [SearchHit]) -> SearchHit? {
        guard let top = hits.first, top.qualifiesForWhereIsCard else { return nil }
        return top
    }

    /// Search input that is only punctuation / FTS syntax is treated as empty.
    static func isSearchable(_ text: String) -> Bool { !SearchQuery.tokens(text).isEmpty }

    static func symbol(for type: SearchEntityType) -> String {
        switch type {
        case .chore: return "checklist"; case .project: return "hammer"; case .thing: return "refrigerator"
        case .inventoryItem: return "shippingbox"; case .measurement: return "ruler"; case .space: return "square.split.bottomrightquarter"
        case .storageSpot: return "archivebox"
        }
    }
}

// MARK: - People (housemate colors)

extension TIK {
    static let personPalette = ["#2F80ED", "#EB5757", "#27AE60", "#F2994A", "#9B51E0", "#00A3A3", "#E0457B", "#8D6E63"]
    static let personPaletteNames = ["Blue", "Red", "Green", "Orange", "Purple", "Teal", "Pink", "Brown"]

    /// First palette color not used yet (cycles when all are used).
    static func nextPersonColor(existing: [String?]) -> String {
        let used = Set(existing.compactMap { $0?.uppercased() })
        return personPalette.first { !used.contains($0.uppercased()) } ?? personPalette[existing.count % personPalette.count]
    }

    /// "#RRGGBB" / "RRGGBB" → 0…1 components.
    static func rgb(hex: String?) -> (r: Double, g: Double, b: Double)? {
        guard var s = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    static func initial(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
    }
}

// MARK: - Measurements

extension TIK {
    static func measurementKindTitle(_ k: HomeMeasurement.Kind) -> String {
        switch k {
        case .opening: return "Opening"; case .wall: return "Wall"; case .door: return "Door"; case .window: return "Window"
        case .zone: return "Zone"; case .general, .unknown: return "General"
        }
    }

    /// "32 W × 40 D in" style summary (known axes only).
    static func dimsSummary(_ d: Dims3, system: UnitSystem) -> String {
        var parts: [String] = []
        if let w = d.width { parts.append("\(HomeLengthFormatter.formatInches(w, system: system)) W") }
        if let dd = d.depth { parts.append("\(HomeLengthFormatter.formatInches(dd, system: system)) D") }
        if let h = d.height { parts.append("\(HomeLengthFormatter.formatInches(h, system: system)) H") }
        return parts.isEmpty ? "No dimensions" : parts.joined(separator: " × ")
    }

    /// "Goes into" candidates (FR-MSR-20): openings and walls first, then most recently updated.
    static func fitTargetOrder(_ ms: [HomeMeasurement]) -> [HomeMeasurement] {
        func rank(_ k: HomeMeasurement.Kind) -> Int { k == .opening ? 0 : k == .wall ? 1 : 2 }
        return ms.sorted { (rank($0.kind), -$0.updatedAt.timeIntervalSince1970) < (rank($1.kind), -$1.updatedAt.timeIntervalSince1970) }
    }

    /// Plain-language axis line for the fit banner.
    static func axisText(_ v: AxisVerdict, axis: String) -> String? {
        let f = { (x: Double) in HomeLengthFormatter.formatInches(x) }
        switch v {
        case .fits(let s): return "\(axis): \(f(s)) to spare"
        case .tight(let s): return "\(axis): tight (\(f(s)) to spare)"
        case .tooBig(let by): return "\(axis): \(f(by)) too big"
        case .protrudes(let by): return "\(axis): sticks out \(f(by))"
        case .unknown: return nil
        }
    }
}

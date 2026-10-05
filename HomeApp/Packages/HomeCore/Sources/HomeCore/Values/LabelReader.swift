import Foundation

/// What a photo of an appliance's rating plate / label suggests (the "Scan label" button on the item form).
/// Every value is a suggestion the user checks before saving.
public struct LabelGuess: Hashable, Sendable {
    public var brand: String?
    public var model: String?
    public var serial: String?
    /// `ThingTemplate` key, e.g. "refrigerator", "water_heater".
    public var templateKey: String?
    /// Category for items with no template (air conditioner, microwave…); the template's category otherwise.
    public var category: Thing.Category?
    /// Lowercase noun for the kind of item ("refrigerator", "furnace", "air conditioner").
    public var kind: String?
    /// Suggested item name, e.g. "Whirlpool refrigerator".
    public var name: String?
    /// Manufacture date, when the label prints one ("MFG DATE 03/2019"): a purchase-date suggestion.
    public var manufactureDate: LocalDate?
    /// Template field values (only keys the guessed template has): `capacityGal`, `screenSize`, `fuel`, `type`.
    public var attributes: [String: JSONValue]

    public init(brand: String? = nil, model: String? = nil, serial: String? = nil, templateKey: String? = nil,
                category: Thing.Category? = nil, kind: String? = nil, name: String? = nil,
                manufactureDate: LocalDate? = nil, attributes: [String: JSONValue] = [:]) {
        self.brand = brand; self.model = model; self.serial = serial; self.templateKey = templateKey
        self.category = category; self.kind = kind; self.name = name
        self.manufactureDate = manufactureDate; self.attributes = attributes
    }

    /// Nothing useful was read.
    public var isEmpty: Bool { brand == nil && model == nil && serial == nil && templateKey == nil && kind == nil }
}

/// Reads an appliance / HVAC / electronics label from OCR text. Pure (Foundation only) and tested on Linux; the app
/// runs Vision text recognition and passes the recognized rows here (see `rows(from:)`).
///
/// - Brand: a list of common appliance, HVAC, electronics and outdoor brands, matched case-insensitively as whole
///   words; the first one on the label (the logo is usually at the top) wins.
/// - Model / serial: the code after "MODEL", "MODEL NO", "MOD", "M/N", "MODEL#" / "SERIAL", "SER NO", "S/N", "SN",
///   on the same row, or on the next row when the label stands alone ("MODEL NO.   SERIAL NO." over the values).
/// - Kind: keywords ("refrigerator", "water heater", "furnace", "TV"…), then brands that only make one kind of thing.
/// - Manufacture date after "MFG DATE", "MFD", "DATE CODE", "MANUFACTURED" when it is a recognizable date.
public enum LabelReader {

    // MARK: Entry points

    public static func read(text: String, today: LocalDate? = nil) -> LabelGuess {
        read(lines: text.components(separatedBy: .newlines), today: today)
    }

    /// `lines`: OCR rows, top to bottom. `today`: dates after it are ignored.
    public static func read(lines raw: [String], today: LocalDate? = nil) -> LabelGuess {
        let lines = raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var guess = LabelGuess()
        guard !lines.isEmpty else { return guess }

        let normalized = lines.map(normalize)
        let codes = labeledValues(lines, today: today)
        guess.model = codes.model
        guess.serial = codes.serial
        guess.manufactureDate = codes.date

        let brand = findBrand(normalized)
        guess.brand = brand?.display

        let all = " " + normalized.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " | ") + " "
        if let kind = findKind(all, brandImplied: brand?.implies) {
            guess.templateKey = kind.templateKey
            guess.kind = kind.noun
            guess.category = kind.templateKey.flatMap(ThingTemplate.find)?.category ?? kind.category
        }
        guess.attributes = attributes(for: guess.templateKey, lines: lines, normalizedAll: all)

        let brandName = brand?.nameForTitle
        switch (brandName, guess.kind, guess.model) {
        case let (b?, k?, _): guess.name = "\(b) \(k)"
        case let (nil, k?, _): guess.name = k.prefix(1).uppercased() + k.dropFirst()
        case let (b?, nil, m?): guess.name = "\(b) \(m)"
        case let (b?, nil, nil): guess.name = b
        default: guess.name = nil
        }
        return guess
    }

    // MARK: Rows from OCR boxes

    /// One recognized piece of text: `x` = left edge, `y` = vertical center, `height`; normalized 0…1 with the
    /// origin at the top-left.
    public struct Fragment: Hashable, Sendable {
        public var text: String
        public var x: Double
        public var y: Double
        public var height: Double
        public init(text: String, x: Double, y: Double, height: Double) {
            self.text = text; self.x = x; self.y = y; self.height = height
        }
    }

    /// Joins fragments that sit on the same row (centers within half a line height) left to right, so a label and
    /// its value recognized as separate pieces ("MODEL NO." … "WRF555SDFZ") end up on one line. Rows top to bottom.
    public static func rows(from fragments: [Fragment]) -> [String] {
        var rows: [(y: Double, h: Double, items: [Fragment])] = []
        for f in fragments.sorted(by: { $0.y < $1.y }) {
            if let last = rows.last, abs(f.y - last.y) < max(f.height, last.h) * 0.5 {
                var row = last
                row.items.append(f)
                row.y = row.items.map(\.y).reduce(0, +) / Double(row.items.count)
                row.h = max(row.h, f.height)
                rows[rows.count - 1] = row
            } else {
                rows.append((f.y, f.height, [f]))
            }
        }
        return rows.map { $0.items.sorted { $0.x < $1.x }.map(\.text).joined(separator: "  ") }
    }

    // MARK: Normalizing

    /// Uppercase, accents folded, every run of non-alphanumerics → one space, padded with spaces so whole words
    /// can be found with `contains(" WORD ")`.
    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US")).uppercased()
        var out = " "
        var lastSpace = true
        for ch in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) && ch.isASCII {
                out.unicodeScalars.append(ch); lastSpace = false
            } else if !lastSpace {
                out.append(" "); lastSpace = true
            }
        }
        if !lastSpace { out.append(" ") }
        return out
    }

    // MARK: Brands

    struct Brand {
        let display: String
        /// Normalized spellings (see `normalize`), without padding.
        let spellings: [String]
        /// Used in the suggested item name ("GE refrigerator" rather than "GE Appliances refrigerator").
        let short: String?
        /// Kind for brands that make one kind of thing (weaker than a keyword on the label).
        let implies: String?
        /// Words that, right before the match, mean it is not the brand ("NEW YORK").
        let notAfter: [String]

        init(_ display: String, _ spellings: [String] = [], short: String? = nil, implies: String? = nil, notAfter: [String] = []) {
            self.display = display
            let base = LabelReader.normalize(display).trimmingCharacters(in: .whitespaces)
            self.spellings = ([base] + spellings).filter { !$0.isEmpty }
            self.short = short; self.implies = implies; self.notAfter = notAfter
        }

        var nameForTitle: String { short ?? display }
    }

    /// Longer spellings first within a brand; "GE Appliances" before "GE".
    static let brands: [Brand] = [
        Brand("GE Appliances", ["GENERAL ELECTRIC", "GE PROFILE", "GE CAFE"], short: "GE"),
        Brand("GE"),
        Brand("Whirlpool"), Brand("Samsung"), Brand("LG", ["LG ELECTRONICS"]), Brand("Frigidaire"), Brand("Maytag"),
        Brand("KitchenAid", ["KITCHEN AID"]), Brand("Bosch"), Brand("Kenmore"), Brand("Electrolux"), Brand("Amana"),
        Brand("Jenn-Air", ["JENNAIR"]), Brand("Sub-Zero", ["SUBZERO"]), Brand("Thermador"), Brand("Viking"),
        Brand("Miele"), Brand("Haier"), Brand("Hotpoint"), Brand("Speed Queen"), Brand("Fisher & Paykel", ["FISHER PAYKEL"]),
        Brand("Beko"), Brand("Dacor"), Brand("Café", ["CAFE APPLIANCES"]),
        Brand("Carrier"), Brand("Trane"), Brand("Lennox"), Brand("Rheem"), Brand("Ruud"),
        Brand("A.O. Smith", ["AO SMITH"], implies: "water_heater"),
        Brand("Bradford White", implies: "water_heater"), Brand("State Water Heaters", implies: "water_heater"),
        Brand("Rinnai", implies: "water_heater"), Brand("Navien", implies: "water_heater"), Brand("Noritz", implies: "water_heater"),
        Brand("Goodman"), Brand("York", notAfter: ["NEW"]), Brand("Daikin"), Brand("Bryant"), Brand("American Standard"),
        Brand("Payne"), Brand("Heil"), Brand("Coleman"), Brand("Mitsubishi Electric", short: "Mitsubishi"), Brand("Mitsubishi"),
        Brand("Fujitsu"), Brand("Bosch Thermotechnology", short: "Bosch"),
        Brand("Honeywell"), Brand("Google Nest", short: "Nest", implies: "thermostat"), Brand("Nest", implies: "thermostat"),
        Brand("Ecobee", implies: "thermostat"), Brand("Aprilaire"),
        Brand("Sony"), Brand("Vizio", implies: "tv"), Brand("TCL"), Brand("Hisense"), Brand("Panasonic"),
        Brand("Toshiba"), Brand("Philips"), Brand("Insignia"),
        Brand("Netgear"), Brand("Linksys", implies: "router"), Brand("eero", implies: "router"), Brand("TP-Link"), Brand("Arris"),
        Brand("Asus"),
        Brand("InSinkErator", ["IN SINK ERATOR"], implies: "disposal"), Brand("Generac", implies: "generator"),
        Brand("Kohler"), Brand("Chamberlain", implies: "garage_door_opener"), Brand("LiftMaster", ["LIFT MASTER"], implies: "garage_door_opener"),
        Brand("Genie", implies: "garage_door_opener"), Brand("Zoeller", implies: "sump_pump"),
        Brand("Toro"), Brand("Honda"), Brand("Craftsman"), Brand("Husqvarna"), Brand("Ryobi"), Brand("Greenworks"),
        Brand("Cub Cadet"), Brand("John Deere"), Brand("Troy-Bilt", ["TROYBILT"]), Brand("Snapper"),
        Brand("Weber", implies: "grill"), Brand("Traeger", implies: "grill"), Brand("Char-Broil", ["CHARBROIL"], implies: "grill"),
        Brand("Pit Boss", implies: "grill"), Brand("Dyson"), Brand("hOmeLabs", ["HOMELABS"]), Brand("Frigidaire Gallery", short: "Frigidaire"),
    ]

    /// First brand on the label (earliest row, then earliest in the row); the longest spelling wins a tie.
    static func findBrand(_ normalized: [String]) -> Brand? {
        for line in normalized {
            var best: (pos: Int, len: Int, brand: Brand)?
            for brand in brands {
                for spelling in brand.spellings {
                    guard let r = line.range(of: " \(spelling) ") else { continue }
                    let before = line[line.startIndex..<r.lowerBound]
                    if brand.notAfter.contains(where: { before.hasSuffix(" \($0)") }) { continue }
                    let pos = line.distance(from: line.startIndex, to: r.lowerBound)
                    if best == nil || pos < best!.pos || (pos == best!.pos && spelling.count > best!.len) {
                        best = (pos, spelling.count, brand)
                    }
                }
            }
            if let best { return best.brand }
        }
        return nil
    }

    // MARK: Kind of thing

    struct Kind {
        let templateKey: String?
        let noun: String
        let category: Thing.Category?
        let phrases: [String]
        /// The kind is skipped when any of these is on the label ("OVEN" but not "MICROWAVE OVEN").
        let unless: [String]
        init(_ templateKey: String?, _ noun: String, _ phrases: [String], category: Thing.Category? = nil, unless: [String] = []) {
            self.templateKey = templateKey; self.noun = noun; self.phrases = phrases; self.category = category; self.unless = unless
        }
    }

    /// In priority order: a water heater label that mentions a furnace is still a water heater; a furnace label
    /// that mentions the thermostat wiring is still a furnace.
    static let kinds: [Kind] = [
        Kind("water_heater", "water heater", ["WATER HEATER", "WATERHEATER", "HOT WATER HEATER", "TANKLESS"]),
        Kind("dishwasher", "dishwasher", ["DISHWASHER", "DISH WASHER"]),
        Kind(nil, "microwave", ["MICROWAVE", "MICROWAVE OVEN"], category: .appliance),
        Kind("hvac_furnace", "furnace", ["FURNACE", "GAS FURNACE"]),
        Kind("hvac_furnace", "air handler", ["AIR HANDLER", "AIR HANDLING UNIT", "FAN COIL"]),
        Kind(nil, "heat pump", ["HEAT PUMP"], category: .system),
        Kind(nil, "air conditioner", ["AIR CONDITIONER", "CONDENSING UNIT", "CONDENSER", "AIR CONDITIONING"], category: .system),
        Kind(nil, "boiler", ["BOILER"], category: .system),
        Kind("refrigerator", "refrigerator", ["REFRIGERATOR", "REFRIGERATOR FREEZER", "FRIDGE", "REFRIG"]),
        Kind("refrigerator", "freezer", ["FREEZER", "UPRIGHT FREEZER", "CHEST FREEZER"]),
        Kind("washer", "washer", ["WASHER", "WASHING MACHINE", "CLOTHES WASHER"], unless: ["PRESSURE WASHER"]),
        Kind("dryer", "dryer", ["DRYER", "CLOTHES DRYER"], unless: ["HAIR DRYER"]),
        Kind("wall_oven", "wall oven", ["WALL OVEN", "BUILT IN OVEN"]),
        Kind("cooktop", "cooktop", ["COOKTOP", "COOK TOP"]),
        Kind("range", "range", ["ELECTRIC RANGE", "GAS RANGE", "INDUCTION RANGE", "FREESTANDING RANGE", "FREE STANDING RANGE",
                                "SLIDE IN RANGE", "RANGE OVEN", "COOKING RANGE", "OVEN"]),
        Kind("dehumidifier", "dehumidifier", ["DEHUMIDIFIER"]),
        Kind(nil, "humidifier", ["HUMIDIFIER"], category: .system),
        Kind("sump_pump", "sump pump", ["SUMP PUMP", "SUMP"]),
        Kind("garage_door_opener", "garage door opener", ["GARAGE DOOR OPENER", "GARAGE DOOR", "DOOR OPENER"]),
        Kind(nil, "garbage disposal", ["GARBAGE DISPOSAL", "FOOD WASTE DISPOSER", "DISPOSER"], category: .appliance),
        Kind(nil, "water softener", ["WATER SOFTENER"], category: .system),
        Kind(nil, "generator", ["GENERATOR", "STANDBY GENERATOR"], category: .system, unless: ["ICE"]),
        Kind("lawn_mower", "lawn mower", ["LAWN MOWER", "LAWNMOWER", "MOWER"]),
        Kind("grill", "grill", ["GRILL", "GAS GRILL", "BARBECUE", "BBQ", "SMOKER", "PELLET GRILL"]),
        Kind("tv", "TV", ["TV", "TELEVISION", "LCD TV", "LED TV", "OLED TV", "SMART TV", "HDTV", "UHD TV"]),
        Kind("router", "router", ["ROUTER", "WIFI ROUTER", "WI FI ROUTER", "WIRELESS ROUTER", "MESH WIFI"]),
        Kind("thermostat", "thermostat", ["THERMOSTAT"]),
    ]

    /// Kinds implied by a brand alone, by the key used in `Brand.implies`.
    static func impliedKind(_ key: String) -> Kind? {
        switch key {
        case "disposal": return kinds.first { $0.noun == "garbage disposal" }
        case "generator": return kinds.first { $0.noun == "generator" }
        default: return kinds.first { $0.templateKey == key }
        }
    }

    static func findKind(_ all: String, brandImplied: String?) -> Kind? {
        for kind in kinds {
            if kind.unless.contains(where: { all.contains(" \($0) ") }) { continue }
            if kind.phrases.contains(where: { all.contains(" \($0) ") }) { return kind }
        }
        if let key = brandImplied, let kind = impliedKind(key) { return kind }
        // "50 GAL" with no other clue: a tank water heater.
        if let gal = gallons(all), gal >= 20 { return kinds.first { $0.templateKey == "water_heater" } }
        return nil
    }

    // MARK: Template fields

    static func attributes(for templateKey: String?, lines: [String], normalizedAll all: String) -> [String: JSONValue] {
        guard let key = templateKey, let template = ThingTemplate.find(key) else { return [:] }
        var out: [String: JSONValue] = [:]
        func set(_ field: String, _ candidates: [String]) {
            guard let f = template.fields.first(where: { $0.key == field }) else { return }
            if let choices = f.choices {
                if let pick = candidates.first(where: { choices.contains($0) }) { out[field] = .string(pick) }
            } else if let first = candidates.first {
                out[field] = .string(first)
            }
        }
        func has(_ phrase: String) -> Bool { all.contains(" \(phrase) ") }

        // Fuel
        var fuel: [String] = []
        if has("NATURAL GAS") || has("NAT GAS") { fuel = ["natural gas", "gas"] }
        else if has("PROPANE") || has("LP GAS") || has("LPG") || has("L P GAS") { fuel = ["propane", "gas"] }
        else if has("HEAT PUMP") || has("HYBRID") { fuel = ["heat pump"] }
        else if has("GAS FIRED") || has("GAS") { fuel = ["gas"] }
        else if has("OIL FIRED") || has("OIL BURNER") { fuel = ["oil"] }
        else if has("INDUCTION") { fuel = ["induction"] }
        else if has("PELLET") || has("PELLETS") { fuel = ["pellet"] }
        else if has("CHARCOAL") { fuel = ["charcoal"] }
        else if ["DRYER", "RANGE", "WATER HEATER", "FURNACE", "COOKTOP", "OVEN", "GRILL"].contains(where: { has("ELECTRIC \($0)") }) {
            fuel = ["electric"]
        }
        if !fuel.isEmpty { set("fuel", fuel) }

        switch key {
        case "water_heater":
            if let gal = gallons(all), gal >= 1 { out["capacityGal"] = .number(gal) }
            if has("TANKLESS") { set("type", ["tankless"]) }
        case "tv":
            if let size = screenSize(lines) { out["screenSize"] = .number(size) }
        default:
            break
        }
        return out
    }

    /// "50 GAL", "40 U.S. GALLONS" (normalized: "40 U S GALLONS"); flow rates ("GAL MIN", "GPM") are skipped.
    static func gallons(_ all: String) -> Double? {
        let pattern = #" (\d{1,3})(?: (\d))? (?:U S |US )?(?:GAL|GALS|GALLON|GALLONS) (?!MIN |PER |HR |H )"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = all as NSString
        for m in re.matches(in: all, range: NSRange(location: 0, length: ns.length)) {
            guard let whole = Double(ns.substring(with: m.range(at: 1))) else { continue }
            var value = whole
            if m.range(at: 2).location != NSNotFound, let dec = Double(ns.substring(with: m.range(at: 2))) { value += dec / 10 }
            if value > 0 && value <= 200 { return value }
        }
        return nil
    }

    /// `55" CLASS`, `65 IN CLASS`, `SCREEN SIZE: 55`.
    static func screenSize(_ lines: [String]) -> Double? {
        let patterns = [#"(?<![\d.])(\d{2,3})\s*(?:"|”|''|IN\.?|INCH(?:ES)?)?\s*CLASS\b"#,
                        #"SCREEN\s*SIZE\D{0,12}?(\d{2,3})(?!\d)"#]
        for line in lines {
            let up = line.uppercased()
            for p in patterns {
                if let s = firstGroup(p, in: up), let v = Double(s), (13...120).contains(v) { return v }
            }
        }
        return nil
    }

    // MARK: Model, serial, date

    enum Field: Int { case model, serial, date }

    static let fieldPatterns: [(Field, String)] = [
        (.model, #"MODEL\s*(?:NUMBER|NO\.?|NUM\.?|#)?|MOD\.?\s*(?:NO\.?|#)?|MDL\.?|M\s*/\s*N|M\.N\.|MODELO|MODELE"#),
        (.serial, #"SERIAL\s*(?:NUMBER|NO\.?|NUM\.?|#)?|SER\.?\s*(?:NO\.?|#)|S\s*/\s*N|S\.N\.|SN|SERIE"#),
        (.date, #"(?:MFG|MFD|MFR)\.?\s*DATE|DATE\s*OF\s*MANUFACTURE|MANUFACTURE\s*DATE|MANUFACTURING\s*DATE|MANUFACTURED(?:\s*ON)?|PRODUCTION\s*DATE|DATE\s*CODE|MFG\.?|MFD\.?|DATE"#),
    ]

    static let labelRegex: NSRegularExpression = {
        let alternatives = fieldPatterns.map { "(\($0.1))" }.joined(separator: "|")
        return try! NSRegularExpression(pattern: "(?<![A-Z0-9])(?:\(alternatives))(?![A-Z0-9])")
    }()

    struct LabelHit { let field: Field; let range: NSRange }

    static func labelHits(in upper: String) -> [LabelHit] {
        let ns = upper as NSString
        return labelRegex.matches(in: upper, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            for (i, entry) in fieldPatterns.enumerated() where m.range(at: i + 1).location != NSNotFound {
                return LabelHit(field: entry.0, range: m.range)
            }
            return nil
        }
    }

    /// Words between a label and its value ("MODEL NO./NO DE MODELE:").
    static let fillerWords: Set<String> = ["NO", "N", "NUMBER", "NUM", "NUMERO", "DE", "DU", "DEL", "MODELE", "MODELO", "MODEL",
                                            "SERIE", "SERIAL", "N°", "Nº", "NO°", "#", "ET", "Y", "AND", "/", "OF"]

    static func labeledValues(_ lines: [String], today: LocalDate?) -> (model: String?, serial: String?, date: LocalDate?) {
        let uppers = lines.map { $0.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US")).uppercased() }
        var model: String?, serial: String?, date: LocalDate?
        for (i, up) in uppers.enumerated() {
            let hits = labelHits(in: up)
            guard !hits.isEmpty else { continue }
            let ns = up as NSString
            var pending: [Field] = []
            var found = Set<Int>()
            for (j, hit) in hits.enumerated() {
                let start = hit.range.location + hit.range.length
                let end = j + 1 < hits.count ? hits[j + 1].range.location : ns.length
                let region = ns.substring(with: NSRange(location: start, length: max(0, end - start)))
                switch hit.field {
                case .model:
                    if let v = codes(in: region, minLength: 3).first { if model == nil { model = v }; found.insert(Field.model.rawValue) }
                    else if !pending.contains(.model) { pending.append(.model) }
                case .serial:
                    if let v = codes(in: region, minLength: 4).first { if serial == nil { serial = v }; found.insert(Field.serial.rawValue) }
                    else if !pending.contains(.serial) { pending.append(.serial) }
                case .date:
                    if let d = parseDate(region, today: today) { if date == nil { date = d }; found.insert(Field.date.rawValue) }
                    else if !pending.contains(.date) { pending.append(.date) }
                }
            }
            pending.removeAll { found.contains($0.rawValue) }
            // Labels with nothing after them: the values are on the next row ("MODEL NO.  SERIAL NO." / "ABC123  K456").
            guard !pending.isEmpty, i + 1 < uppers.count, labelHits(in: uppers[i + 1]).isEmpty else { continue }
            let next = uppers[i + 1]
            var nextCodes = codes(in: next, minLength: 3)
            for field in pending {
                switch field {
                case .model:
                    if !nextCodes.isEmpty { let v = nextCodes.removeFirst(); if model == nil { model = v } }
                case .serial:
                    if let k = nextCodes.firstIndex(where: { $0.count >= 4 }) {
                        let v = nextCodes.remove(at: k); if serial == nil { serial = v }
                    }
                case .date:
                    if date == nil { date = parseDate(next, today: today) }
                }
            }
        }
        return (model, serial, date)
    }

    /// Model / serial-looking tokens in order: letters, digits and inner `-` `/` `.`, at least one digit, not an
    /// electrical rating ("120V", "60HZ") or a date.
    static func codes(in region: String, minLength: Int) -> [String] {
        let trimSet = CharacterSet(charactersIn: ":;,.#/-–—()[]{}*'\"|=_")
        var out: [String] = []
        for raw in region.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let token = String(raw).trimmingCharacters(in: trimSet.union(.whitespaces)).uppercased()
            guard !token.isEmpty, !fillerWords.contains(token) else { continue }
            guard token.count >= minLength, token.count <= 30,
                  token.unicodeScalars.allSatisfy({ ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "-/.".unicodeScalars.contains($0) }),
                  token.contains(where: \.isNumber),
                  // All-digit tokens ("115", "6.5") are ratings or quantities unless long, like a serial.
                  token.contains(where: \.isLetter) || token.filter(\.isNumber).count >= 5,
                  !isRating(token), parseDate(token, today: nil) == nil else { continue }
            out.append(token)
        }
        return out
    }

    static let ratingRegex = try! NSRegularExpression(
        pattern: #"^\d+(?:[.,/]\d+)*(?:V|VAC|VDC|VOLTS?|HZ|A|AMPS?|W|WATTS?|KW|KWH|PSI|BTU|BTUH|LBS?|KG|GAL|L|IN|MM|CM|FT|MA|PH|F|C)$"#)

    static func isRating(_ token: String) -> Bool {
        ratingRegex.firstMatch(in: token, range: NSRange(location: 0, length: (token as NSString).length)) != nil
    }

    // MARK: Dates

    static let months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]

    /// First recognizable date in `text`: `2019-03-15`, `03/15/2019`, `15.03.2019`, `03/2019`, `2019-03`,
    /// `MAR 2019`, `March 2019`, `2019 MAR`. Month-only dates use the 1st. Years 1950…today.
    public static func parseDate(_ text: String, today: LocalDate?) -> LocalDate? {
        let up = text.uppercased()
        let monthAlt = "(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)[A-Z]*\\.?"
        let patterns: [(String, ([String]) -> LocalDate?)] = [
            (#"(?<!\d)(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?!\d)"#, { g in make(Int(g[0]), Int(g[1]), Int(g[2])) }),
            (#"(?<!\d)(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})(?!\d)"#, { g in
                guard let a = Int(g[0]), let b = Int(g[1]) else { return nil }
                return a > 12 ? make(Int(g[2]), b, a) : make(Int(g[2]), a, b) }),
            ("(?<![A-Z])\(monthAlt)[\\s,/-]*(\\d{4})(?!\\d)", { g in make(Int(g[1]), monthNumber(g[0]), 1) }),
            ("(?<!\\d)(\\d{4})[\\s,/-]*\(monthAlt)(?![A-Z])", { g in make(Int(g[0]), monthNumber(g[1]), 1) }),
            (#"(?<![\d./-])(\d{1,2})[-/.](\d{4})(?![\d./-])"#, { g in make(Int(g[1]), Int(g[0]), 1) }),
            (#"(?<![\d./-])(\d{4})[-/.](\d{1,2})(?![\d./-])"#, { g in make(Int(g[0]), Int(g[1]), 1) }),
        ]
        for (pattern, build) in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = up as NSString
            for m in re.matches(in: up, range: NSRange(location: 0, length: ns.length)) {
                let groups = (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
                guard let d = build(groups), d.year >= 1950 else { continue }
                if let today, d > today { continue }
                return d
            }
        }
        return nil
    }

    static func monthNumber(_ s: String) -> Int? {
        months.firstIndex(of: String(s.prefix(3))).map { $0 + 1 }
    }

    static func make(_ y: Int?, _ m: Int?, _ d: Int?) -> LocalDate? {
        guard let y, let m, let d, (1950...2200).contains(y), (1...12).contains(m),
              d >= 1, d <= LocalDate.daysInMonth(year: y, month: m) else { return nil }
        return LocalDate(y, m, d)
    }

    static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound else { return nil }
        return (text as NSString).substring(with: m.range(at: 1))
    }
}

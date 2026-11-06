import Foundation

public struct EstimateGuideSource: Hashable, Identifiable, Sendable {
    public let label: String
    public let url: URL
    public var id: URL { url }

    fileprivate init(_ label: String, _ url: String) {
        self.label = label
        self.url = URL(string: url)!
    }
}

/// Starter worksheets apply to the selected scope only. Owners can change each price or use their own breakdown.
public enum CustomScopeStarter: String, CaseIterable, Identifiable, Sendable {
    case interiorPaint, vinylFloor, mulchBeds, smallHandyman, halfDayHandyman, fullDayHandyman
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .interiorPaint: "Paint interior walls"
        case .vinylFloor: "Install vinyl plank flooring"
        case .mulchBeds: "Mulch a planting bed"
        case .smallHandyman: "Small handyman visit · under 2 hours"
        case .halfDayHandyman: "Handyman visit · 2–5 hours"
        case .fullDayHandyman: "Handyman visit · full day"
        }
    }
    public var needsDimensions: Bool { self == .interiorPaint || self == .vinylFloor || self == .mulchBeds }

    public var assumptions: String {
        switch self {
        case .interiorPaint:
            "DIY estimates wall paint. Defaults are 8-foot walls, two coats, no deducted openings and 350 sq. ft. per gallon. The professional room guide uses floor area for a typical room and includes materials and labor. Add separate allowances for trim, ceilings, repairs or new tools."
        case .vinylFloor:
            "Allows 10% for offcuts and buys full 20.1 sq. ft. cartons. Professional installation uses the floor area before offcuts. Removal, subfloor repair and transitions are separate."
        case .mulchBeds:
            "Uses length × width × depth. The starting depth is 3 inches. Buy full 1.5 cu. ft. bags. The professional option adds spreading labor by cubic yard. Delivery, removal and minimum service charges are separate."
        default:
            "US whole-visit comparison for general handyman work, including a mix of project costs. Use this as an alternative to itemizing the same work. Specialty trades require their own scope and quote."
        }
    }

    private static let coverage = EstimateGuideSource("Sherwin-Williams · paint coverage", "https://www.sherwin-williams.com/en-us/color/color-tools/paint-calculator")
    private static let glidden = EstimateGuideSource("Home Depot · Glidden Premium gallon", "https://www.homedepot.com/p/202246794")
    private static let behr = EstimateGuideSource("Home Depot · Behr Marquee gallon", "https://www.homedepot.com/p/308214409")
    private static let roomPaint = EstimateGuideSource("Angi · professional room painting", "https://www.angi.com/articles/how-much-does-it-cost-paint-room.htm")
    private static let vinyl = EstimateGuideSource("Home Depot · US vinyl plank cost guide", "https://www.homedepot.com/services/c/cost-install-vinyl-floors/c1e5c4c07")
    private static let carton = EstimateGuideSource("Home Depot · example 20.1 sq. ft. carton", "https://www.homedepot.com/p/309083456")
    private static let cuts = EstimateGuideSource("Home Depot · measuring and offcuts", "https://www.homedepot.com/c/ah/how-to-install-vinyl-plank-flooring/9ba683603be9fa5395fab90188fe437f")
    private static let bags = EstimateGuideSource("Home Depot · Earthgro 1.5 cu. ft. mulch", "https://www.homedepot.com/b/Outdoors-Garden-Center-Landscaping-Supplies-Mulch-Wood-Mulch/Earthgro/Brown/N-5yc1vZc9nxZ37wZ1z0vl9p")
    private static let mulchVolume = EstimateGuideSource("Home Depot · mulch coverage", "https://www.homedepot.com/calculator/mulch")
    private static let mulchLabor = EstimateGuideSource("Angi · mulch installation labor", "https://www.angi.com/articles/how-much-does-mulch-delivery-and-install-cost.htm")
    private static let handyman = EstimateGuideSource("Thumbtack · US handyman prices", "https://www.thumbtack.com/p/handyman-prices")

    public var sources: [EstimateGuideSource] {
        switch self {
        case .interiorPaint: [Self.coverage, Self.glidden, Self.behr, Self.roomPaint]
        case .vinylFloor: [Self.vinyl, Self.carton, Self.cuts]
        case .mulchBeds: [Self.bags, Self.mulchVolume, Self.mulchLabor]
        default: [Self.handyman]
        }
    }

    public static func suggested(for title: String, mode: Chore.WorkMode) -> Self? {
        let words = Set(title.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        func has(_ tokens: Set<String>) -> Bool { !words.isDisjoint(with: tokens) }
        if has(["remove", "removal", "clean", "repair", "strip", "test"]) { return nil }
        if has(["paint", "repaint", "painting", "repainting"]),
           has(["room", "bedroom", "kitchen", "bathroom", "hallway", "wall", "walls", "interior"]),
           !has(["ceiling", "ceilings", "cabinet", "cabinets", "door", "doors", "exterior", "trim"]) { return .interiorPaint }
        if has(["vinyl", "lvp", "lvt"]) && has(["floor", "flooring", "plank", "planks", "install", "lay"]) { return .vinylFloor }
        if has(["mulch", "mulching"]) { return .mulchBeds }
        return nil
    }

    /// Bare dimensions use the editor's labeled feet setting. Convert explicit metric or inch units, reject three-axis sizes.
    public static func roomSize(in title: String) -> (length: Double, width: Double)? {
        let input = title.lowercased()
        let pattern = #"(?<![\d.\-])\b(\d+(?:\.\d+)?)\s*(feet|foot|ft|meters?|metres?|m|cm|inches|in|['′"″])?\s*(?:x|×|\bby\b)\s*(\d+(?:\.\d+)?)\s*(feet|foot|ft|meters?|metres?|m|cm|inches|in|['′"″])?(?![a-z0-9.])"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              let whole = Range(result.range, in: input) else { return nil }
        let rest = input[whole.upperBound...].trimmingCharacters(in: .whitespaces)
        if rest.range(of: #"^(?:x|×|by)\s*\d"#, options: .regularExpression) != nil { return nil }
        func part(_ index: Int) -> String? {
            Range(result.range(at: index), in: input).map { String(input[$0]) }
        }
        func feet(_ value: Double, _ unit: String?) -> Double {
            switch unit {
            case "cm": value / 30.48
            case "m", "meter", "metre", "meters", "metres": value / 0.3048
            case "in", "inches", "\"", "″": value / 12
            default: value
            }
        }
        guard let a = part(1).flatMap(Double.init), let b = part(3).flatMap(Double.init) else { return nil }
        let length = feet(a, part(2) ?? part(4)), width = feet(b, part(4) ?? part(2))
        guard (0.01...10_000).contains(length), (0.01...10_000).contains(width) else { return nil }
        return (length, width)
    }

    /// Prices per pack when packSize is present. Only US dollar worksheets receive the published US examples.
    public func lines(length: Double?, width: Double?, heightOrDepth: Double?, coats: Int, openings: Double,
                      currency: String, mode: Chore.WorkMode) throws -> [WorkEstimateLine] {
        func dollars(_ cents: Int64) -> Money? { currency == "USD" ? Money(cents: cents, currency: currency) : nil }
        func source(_ basis: String, _ guides: [EstimateGuideSource]) -> String {
            basis + " · US guides checked Nov 2026. " + guides.map { $0.url.absoluteString }.joined(separator: " ")
        }
        if !needsDimensions {
            guard mode == .hirePro, currency == "USD" else { throw WorkEstimateError("This US whole-job guide is for hiring a professional.") }
            let rate: (Int64, Int64)
            switch self {
            case .smallHandyman: rate = (10_100, 25_700)
            case .halfDayHandyman: rate = (21_200, 56_800)
            case .fullDayHandyman: rate = (65_200, 184_200)
            default: throw WorkEstimateError("Choose a visit length.")
            }
            return [.init(kind: .wholeJob, name: title, quantity: 1, unit: "visit", unitPrice: dollars(rate.0), highUnitPrice: dollars(rate.1),
                          source: source("Whole visit, national project range. Confirm local minimum and what is included", [Self.handyman]))]
        }
        guard let length, let width, (0.01...10_000).contains(length), (0.01...10_000).contains(width) else {
            throw WorkEstimateError("Enter the measured length and width in feet.")
        }
        let floor = Decimal(length) * Decimal(width)
        switch self {
        case .interiorPaint where mode == .hirePro:
            return [.init(kind: .wholeJob, name: "Interior wall painting · materials and labor", quantity: floor, unit: "sq ft of floor",
                          unitPrice: dollars(200), highUnitPrice: dollars(600),
                          source: source("Room-size guide uses $2–$6 per square foot of floor area. Typical room, standard-height walls. Get a quote for unusual height, coats or repairs", [Self.roomPaint]))]
        case .interiorPaint:
            let height = heightOrDepth ?? 8
            guard (0.1...100).contains(height), (1...10).contains(coats), openings.isFinite, openings >= 0 else {
                throw WorkEstimateError("Check the wall height, coat count and opening area.")
            }
            let walls = 2 * (Decimal(length) + Decimal(width)) * Decimal(height) - Decimal(openings)
            guard walls > 0 else { throw WorkEstimateError("Openings must cover less than the total wall area.") }
            let gallons = walls * Decimal(coats) / 350
            return [.init(kind: .material, name: "Interior wall paint", quantity: gallons, unit: "gal", packSize: 1,
                          unitPrice: dollars(2_898), highUnitPrice: dollars(5_398),
                          source: source("\(walls) sq. ft. of walls × \(coats) coat(s) ÷ 350 sq. ft./gal. One-gallon retail examples", [Self.coverage, Self.glidden, Self.behr]))]
        case .vinylFloor:
            // Use the guide per sq. ft., converted to the example carton's coverage.
            let box = Decimal(201) / 10
            let material = WorkEstimateLine(kind: .material, name: "Vinyl plank flooring", quantity: floor * 110 / 100, unit: "sq ft",
                packSize: box, unitPrice: dollars(4_020), highUnitPrice: dollars(8_040),
                source: source("Floor area plus 10% for cuts. A 20.1 sq. ft. carton at the US material guide of $2–$4/sq. ft.", [Self.vinyl, Self.carton, Self.cuts]))
            if mode == .diy { return [material] }
            return [material, .init(kind: .labor, name: "Install vinyl plank", quantity: floor, unit: "sq ft",
                          unitPrice: dollars(300), highUnitPrice: dollars(500),
                          source: source("Installation labor $3–$5/sq. ft. applied to actual floor area", [Self.vinyl]))]
        case .mulchBeds:
            let depth = heightOrDepth ?? 3
            guard (0.1...24).contains(depth) else { throw WorkEstimateError("Enter the mulch depth in inches.") }
            let volume = floor * Decimal(depth) / 12
            let material = WorkEstimateLine(kind: .material, name: "Wood mulch", quantity: volume, unit: "cu ft",
                packSize: Decimal(15) / 10, unitPrice: dollars(397),
                source: source("Area × depth ÷ 12. One 1.5 cu. ft. bag of Earthgro brown mulch at $3.97", [Self.mulchVolume, Self.bags]))
            if mode == .diy { return [material] }
            return [material, .init(kind: .labor, name: "Spread mulch", quantity: volume / 27, unit: "cu yd",
                          unitPrice: dollars(2_000), highUnitPrice: dollars(5_000),
                          source: source("US spreading labor $20–$50 per cubic yard; delivery and any service minimum are separate", [Self.mulchLabor]))]
        default: throw WorkEstimateError("Choose a measured job.")
        }
    }
}

import Foundation

/// National US planning examples, reviewed November 2026. These are never written as actual costs.
public enum MaintenanceIdea: String, CaseIterable, Identifiable, Sendable {
    case gutters, furnace, cooling, dryer, filter, closet
    public var id: Self { self }
    public var title: String {
        switch self {
        case .closet: return "Renovate a closet"
        case .gutters: return "Clean the gutters"
        case .furnace: return "Schedule a furnace tune-up"
        case .cooling: return "Check the cooling system"
        case .dryer: return "Clean the dryer vent"
        case .filter: return "Check the HVAC air filter"
        }
    }
    public var detail: String {
        switch self {
        case .closet: return "Measure the space and choose a storage layout. Compare a self-installed kit with a contractor’s custom installation."
        case .gutters: return "If your home has gutters, check for debris after leaf fall and before heavy rain. Height and access affect a professional quote."
        case .furnace: return "If your home uses a furnace, arrange a check before the heating season. Ask which checks and cleaning the quote includes."
        case .cooling: return "If you use air conditioning, arrange a preseason check. Routine service and repairs have different prices."
        case .dryer: return "If your home has a vented dryer, check its maintenance instructions. Vent length and access affect cleaning costs."
        case .filter: return "Check the filter used by your heating or cooling equipment. Use its condition and the manufacturer’s instructions to decide when to replace it."
        }
    }
    public var rangeUSD: ClosedRange<Int>? {
        switch self { case .gutters: return 163...333; case .furnace: return 150...200; case .cooling: return 75...200; case .dryer: return 104...188; case .filter: return nil; case .closet: return 1046...3210 }
    }
    public var priceSource: URL? {
        switch self {
        case .gutters: return URL(string: "https://www.thumbtack.com/p/gutter-cleaning-prices")
        case .furnace: return URL(string: "https://www.angi.com/articles/how-much-does-common-furnace-repair-cost.htm")
        case .dryer: return URL(string: "https://www.angi.com/articles/how-much-does-dryer-vent-cleaning-cost.htm")
        case .closet: return URL(string: "https://www.angi.com/articles/how-much-do-custom-closets-cost.htm")
        case .cooling: return URL(string: "https://www.angi.com/articles/importance-annual-ac-tune.htm")
        case .filter: return nil
        }
    }
    public var sourceLabel: String {
        switch self { case .gutters: return "Thumbtack · March 2026"; case .furnace, .dryer, .cooling, .closet: return "Angi · 2026"; default: return "ENERGY STAR maintenance checklist" }
    }
    public var costLabel: String? { rangeUSD.map { "$\($0.lowerBound)–$\($0.upperBound) USD" } }
    public var symbol: String {
        switch self { case .gutters: return "cloud.rain"; case .furnace: return "flame"; case .cooling: return "snowflake"; case .dryer: return "wind"; case .filter: return "aqi.medium"; case .closet: return "cabinet" }
    }
    public var suggestedRepeat: RepeatRule? { self == .filter ? .init(freq: .monthly) : nil }

    public var diyTitle: String {
        switch self {
        case .furnace: return "Prepare for furnace service"
        case .cooling: return "Check the AC filter and service record"
        case .gutters: return "Check and clear reachable gutters"
        default: return title
        }
    }

    public var supplySuggestions: [String] {
        switch self {
        case .gutters: return ["Work gloves", "Garden hose", "Telescoping gutter wand", "Yard waste bags"]
        case .furnace, .cooling, .filter: return ["Replacement HVAC filter", "Flashlight"]
        case .dryer: return ["Dryer vent cleaning kit", "Vacuum cleaner", "Work gloves"]
        case .closet: return ["Tape measure", "Level", "Closet organizer kit", "Drill", "Mounting hardware"]
        }
    }

    /// The same reusable tool can serve several tasks; consumables combine across them.
    public var suggestedSupplyPlan: [ChoreSupply] {
        let equipment: Set<String> = ["Work gloves", "Garden hose", "Telescoping gutter wand", "Flashlight",
                                      "Dryer vent cleaning kit", "Vacuum cleaner", "Tape measure", "Level", "Drill"]
        return ChoreSupply.suggestions(supplySuggestions).map { original in
            var entry = original
            entry.isEquipment = equipment.contains(entry.name)
            return entry
        }
    }

    public var diyBudget: String {
        switch self {
        case .gutters: return "$0–$50 USD · one ground tool"
        case .furnace, .cooling, .filter: return "$10–$50 USD · replacement filter"
        case .dryer: return "$20–$50 USD · cleaning kit"
        case .closet: return "$500–$2,000 USD · organizer kit"
        }
    }
    public var diySource: URL {
        let path: String
        switch self {
        case .gutters: path = "tools-keep-gutter-downspouts-clean.htm"
        case .furnace, .cooling, .filter: path = "how-to-install-furnace-filter.htm"
        case .dryer: path = "hiring-vs-diy-dryer-vent-cleaning.htm"
        case .closet: path = "closet-organizer-cost.htm"
        }
        return URL(string: "https://www.angi.com/articles/" + path)!
    }

    public var diyScope: String {
        switch self {
        case .gutters: return "Assumes an existing hose. You may spend nothing if you own compatible ground tools. Arrange professional help for work at height."
        case .furnace, .cooling: return "DIY covers checking an accessible filter and gathering service records. A professional performs the system tune-up. Confirm the filter size before buying."
        case .filter: return "Inspection uses existing equipment. The guide covers a replacement if needed; confirm the model and size."
        case .dryer: return "The kit budget applies to an accessible vent. Check the manufacturer’s instructions; a long or inaccessible run needs a professional quote."
        case .closet: return "Kit budget only. Check dimensions, fixings and what is included. Electrical or structural changes need a qualified professional."
        }
    }

    /// A matched national study exists for a closet renovation. A kit-only refresh or routine
    /// service has no supported property-specific resale estimate in this catalog.
    public func resaleScenario(isDIY: Bool) -> ClosedRange<Int>? {
        guard self == .closet, !isDIY, let cost = rangeUSD else { return nil }
        let fraction = 0.83
        func roundedHundreds(_ dollars: Int) -> Int { Int((Double(dollars) * fraction / 100).rounded()) * 100 }
        return roundedHundreds(cost.lowerBound)...roundedHundreds(cost.upperBound)
    }

    public static func titleKey(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0 != "the" && $0 != "a" && $0 != "my" }
            .joined(separator: " ")
    }

    public static func visible(month: Int, latitude: Double?, hidden: String) -> [Self] {
        let ignored = Set(hidden.split(separator: ",").map(String.init))
        return seasonalOrder(month: month, latitude: latitude).filter { !ignored.contains($0.rawValue) }
    }

    public static func seasonalOrder(month: Int, latitude: Double?) -> [Self] {
        let seasonalMonth = (latitude ?? 0) < 0 ? ((month + 5) % 12) + 1 : month
        switch seasonalMonth {
        case 3...5: return [.cooling, .gutters, .filter, .dryer, .furnace, .closet]
        case 6...8: return [.filter, .cooling, .dryer, .gutters, .furnace, .closet]
        case 9...11: return [.gutters, .furnace, .dryer, .filter, .cooling, .closet]
        default: return [.furnace, .filter, .dryer, .gutters, .cooling, .closet]
        }
    }
}

import SwiftUI
import HomeCore

/// Where a "+" leads: one of the six create forms, prefilled with the room (and its floor). Spec 02 FR-CNV-31…35.
enum AddDestination: Hashable, Identifiable {
    case todo(spaceID: UUID?, levelID: UUID?)
    case futureProject(spaceID: UUID?, levelID: UUID?)
    /// Opens the project form with status Done and the Done fields (FR-CNV-35).
    case pastWork(spaceID: UUID?, levelID: UUID?)
    case thing(spaceID: UUID?)
    /// Thing form in outdoor mode (Outside level): Outdoor category and outdoor templates first.
    case outdoorThing(spaceID: UUID?)
    /// Thing form that opens the "Scan label" photo flow right away (Stuff tab "Scan an appliance label").
    case scannedThing(spaceID: UUID?)
    case inventory(spaceID: UUID?)
    case measurement(spaceID: UUID?)

    init(kind: AddKind, spaceID: UUID?, levelID: UUID?, outdoor: Bool = false) {
        switch kind {
        case .todo: self = .todo(spaceID: spaceID, levelID: levelID)
        case .futureProject: self = .futureProject(spaceID: spaceID, levelID: levelID)
        case .pastWork: self = .pastWork(spaceID: spaceID, levelID: levelID)
        case .thing: self = outdoor ? .outdoorThing(spaceID: spaceID) : .thing(spaceID: spaceID)
        case .inventory: self = .inventory(spaceID: spaceID)
        case .measurement: self = .measurement(spaceID: spaceID)
        }
    }

    var kind: AddKind {
        switch self {
        case .todo: return .todo
        case .futureProject: return .futureProject
        case .pastWork: return .pastWork
        case .thing, .outdoorThing, .scannedThing: return .thing
        case .inventory: return .inventory
        case .measurement: return .measurement
        }
    }

    var id: String {
        switch self {
        case .todo(let s, let l), .futureProject(let s, let l), .pastWork(let s, let l):
            return "\(kind.rawValue):\(s?.uuidString ?? "-"):\(l?.uuidString ?? "-")"
        case .thing(let s), .inventory(let s), .measurement(let s):
            return "\(kind.rawValue):\(s?.uuidString ?? "-")"
        case .outdoorThing(let s):
            return "\(kind.rawValue)-outdoor:\(s?.uuidString ?? "-")"
        case .scannedThing(let s):
            return "\(kind.rawValue)-scan:\(s?.uuidString ?? "-")"
        }
    }
}

/// Presents the create form for a destination. The forms belong to their features and are self-contained
/// (own `NavigationStack`, dismiss themselves on save/cancel); present this in a sheet.
struct AddRouter: View {
    let destination: AddDestination

    init(destination: AddDestination) { self.destination = destination }

    var body: some View {
        switch destination {
        case .todo(let spaceID, let levelID):
            ChoreForm(spaceID: spaceID, levelID: levelID)
        case .futureProject(let spaceID, let levelID):
            ProjectForm(spaceID: spaceID, levelID: levelID, initialStatus: .idea)
        case .pastWork(let spaceID, let levelID):
            ProjectForm(spaceID: spaceID, levelID: levelID, initialStatus: .done)
        case .thing(let spaceID):
            ThingForm(spaceID: spaceID)
        case .outdoorThing(let spaceID):
            ThingForm(spaceID: spaceID, outdoor: true)
        case .scannedThing(let spaceID):
            ThingForm(spaceID: spaceID, startWithScan: true)
        case .inventory(let spaceID):
            InventoryForm(spaceID: spaceID)
        case .measurement(let spaceID):
            MeasurementForm(spaceID: spaceID)
        }
    }
}

/// Picker rows (mockup 3.2).
struct AddKindInfo {
    let title: String
    let detail: String
    let symbol: String

    static func of(_ kind: AddKind, outdoor: Bool = false) -> AddKindInfo {
        if outdoor {
            switch kind {
            case .thing: return AddKindInfo(title: "Plant or outdoor feature", detail: "Trees, fence, swing set, pool, septic, utility lines…", symbol: "tree")
            case .inventory: return AddKindInfo(title: "Inventory item", detail: "Tools, garden supplies, seasonal gear", symbol: "shippingbox")
            default: break
            }
        }
        switch kind {
        case .todo: return AddKindInfo(title: "To-Do", detail: "Chore or one-off task, with repeat and reminders", symbol: "checklist")
        case .futureProject: return AddKindInfo(title: "Future Project", detail: "Improvement or repair, with estimate", symbol: "hammer")
        case .pastWork: return AddKindInfo(title: "Past Work", detail: "Finished work, with cost, date and receipt", symbol: "clock.arrow.circlepath")
        case .thing: return AddKindInfo(title: "Appliance, Electronic or Furniture", detail: "Specs, dimensions, filters and bulbs", symbol: "sofa")
        case .inventory: return AddKindInfo(title: "Inventory item", detail: "Pantry, clothing or stored item", symbol: "shippingbox")
        case .measurement: return AddKindInfo(title: "Measurement", detail: "Width, depth, height of a spot, door or wall", symbol: "ruler")
        }
    }
}

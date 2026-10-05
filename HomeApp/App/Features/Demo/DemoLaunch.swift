import SwiftUI
import HomeCore
import HomeCoreTesting

/// Screenshot / demo mode. Launch with `-HomeDemo YES` to run on the in-memory sample house (nothing touches the
/// real database, iCloud, calendars or notifications), and `-HomeDemoScreen <id>` to open on one screen.
/// Used by `.github/workflows/screenshots.yml` (see `.claude/skills/app-screenshots/SKILL.md`). Ignored otherwise.
struct DemoLaunch: Equatable {
    /// Screens the screenshot workflow captures. Keep in sync with SCREENS in `.github/workflows/screenshots.yml`.
    enum Screen: String, CaseIterable {
        case onboarding, home, plan, planOutside = "plan-outside", todos, quickAdd = "quick-add", projects, tellHome = "tell-home", stuff
        /// A receipt photo shared from Mail/Photos, open in the "File it" sheet.
        case sharedReceipt = "shared-receipt"
        case addOutside = "add-outside", outdoorTemplates = "outdoor-templates", settings
        /// 2nd floor: the Primary Bedroom's reach-in closet sits inside the room.
        case planUpstairs = "plan-upstairs"
    }

    let screen: Screen

    /// nil unless launched with `-HomeDemo YES`.
    static let current: DemoLaunch? = {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "HomeDemo") else { return nil }
        let screen = defaults.string(forKey: "HomeDemoScreen").flatMap(Screen.init(rawValue:)) ?? .home
        return DemoLaunch(screen: screen)
    }()

    /// The sample house, or an empty home for the onboarding screen.
    @MainActor
    func makeEnvironment() -> AppEnvironment {
        AppEnvironment.preview(sample: screen != .onboarding)
    }

    var tab: AppTab {
        switch screen {
        case .onboarding, .home, .settings: return .home
        case .plan, .planOutside, .addOutside, .outdoorTemplates, .planUpstairs: return .plan
        case .todos, .quickAdd: return .todos
        case .projects, .tellHome, .sharedReceipt: return .projects
        case .stuff: return .stuff
        }
    }

    /// Floor the Plan tab opens on.
    var levelID: UUID? {
        switch screen {
        case .planOutside, .addOutside, .outdoorTemplates: return SampleHome.outsideId
        case .planUpstairs: return SampleHome.secondFloorId
        default: return nil
        }
    }

    var sheet: DemoSheet? {
        switch screen {
        case .quickAdd: return .quickAdd
        case .tellHome: return .tellHome
        case .sharedReceipt: return .sharedReceipt
        case .addOutside: return .addOutside
        case .outdoorTemplates: return .outdoorTemplates
        case .settings: return .settings
        default: return nil
        }
    }
}

enum DemoSheet: String, Identifiable {
    case quickAdd, tellHome, sharedReceipt, addOutside, outdoorTemplates, settings
    var id: String { rawValue }

    static let sampleList = """
    Weekend jobs:
    - [ ] Clean gutters
    - [ ] Replace furnace filter
    - Call the plumber about the slow drain
    - Seal the deck
    """

    /// The founder's own words, so the Tell Home screenshot shows a project card with amount and date.
    static let tellHomeSentence =
        "hey we're thinking of getting a new fence in 3 months & wanna spend 10k, could u put in that idea in"

    @MainActor @ViewBuilder
    var view: some View {
        switch self {
        case .quickAdd:
            QuickCaptureSheet(initialText: Self.sampleList)
        case .tellHome:
            TellHomeSheet(initialText: Self.tellHomeSentence)
        case .sharedReceipt:
            SharedInboxSheet(item: SharedInboxItem.demoReceipt)
        case .addOutside:
            AddPicker(spaceID: nil, levelID: SampleHome.outsideId, preselected: nil, placeName: "Backyard", outdoor: true)
        case .outdoorTemplates:
            TemplatePickerSheet(selectedKey: nil, outdoorFirst: true) { _ in }
        case .settings:
            SettingsView()
        }
    }
}

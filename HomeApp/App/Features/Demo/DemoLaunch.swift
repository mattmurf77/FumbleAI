import SwiftUI
import HomeCore
import HomeCoreTesting

/// Screenshot / demo mode. Launch with `-HomeDemo YES` to run on the in-memory sample house (nothing touches the
/// real database, iCloud, calendars or notifications), and `-HomeDemoScreen <id>` to open on one screen.
/// Used by `.github/workflows/screenshots.yml` (see `.claude/skills/app-screenshots/SKILL.md`). Ignored otherwise.
struct DemoLaunch: Equatable {
    /// Screens the screenshot workflow captures. Keep in sync with SCREENS in `.github/workflows/screenshots.yml`.
    enum Screen: String, CaseIterable {
        case onboarding, home, plan, planOutside = "plan-outside", todos, quickAdd = "quick-add", projects, stuff
        case addOutside = "add-outside", outdoorTemplates = "outdoor-templates", settings
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
    func makeEnvironment() -> AppEnvironment {
        AppEnvironment.preview(sample: screen != .onboarding)
    }

    var tab: AppTab {
        switch screen {
        case .onboarding, .home, .settings: return .home
        case .plan, .planOutside, .addOutside, .outdoorTemplates: return .plan
        case .todos, .quickAdd: return .todos
        case .projects: return .projects
        case .stuff: return .stuff
        }
    }

    /// Floor the Plan tab opens on.
    var levelID: UUID? {
        switch screen {
        case .planOutside, .addOutside, .outdoorTemplates: return SampleHome.outsideId
        default: return nil
        }
    }

    var sheet: DemoSheet? {
        switch screen {
        case .quickAdd: return .quickAdd
        case .addOutside: return .addOutside
        case .outdoorTemplates: return .outdoorTemplates
        case .settings: return .settings
        default: return nil
        }
    }
}

enum DemoSheet: String, Identifiable {
    case quickAdd, addOutside, outdoorTemplates, settings
    var id: String { rawValue }

    static let sampleList = """
    Weekend jobs:
    - [ ] Clean gutters
    - [ ] Replace furnace filter
    - Call the plumber about the slow drain
    - Seal the deck
    """

    @ViewBuilder
    var view: some View {
        switch self {
        case .quickAdd:
            QuickCaptureSheet(initialText: Self.sampleList)
        case .addOutside:
            AddPicker(spaceID: nil, levelID: SampleHome.outsideId, preselected: nil, placeName: "Backyard", outdoor: true)
        case .outdoorTemplates:
            TemplatePickerSheet(selectedKey: nil, outdoorFirst: true) { _ in }
        case .settings:
            SettingsView()
        }
    }
}

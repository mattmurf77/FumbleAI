import SwiftUI
import HomeCore

/// Root of the no-property flow (spec 01 "Onboarding entry", mockup 6.1). RootView shows it when no property
/// exists and swaps to the Plan screen when `onFinished` fires (after the plan commit, or when an iCloud restore
/// brings a home down).
///
/// Steps: iCloud restore check (8 s) → address (optional) → path chooser (Scan / Blocks / Trace / Rough) →
/// path flow → Review → commit (`PlanCommitting`) → exterior seeding in the background.
@MainActor
struct OnboardingFlow: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model: OnboardingModel
    let onFinished: () -> Void
    @State private var showingPlanSetup = false
    private var addingPlan = false
    private var bringRecords: (() -> Void)?

    init(bringRecords: (() -> Void)? = nil, onFinished: @escaping () -> Void) {
        self.bringRecords = bringRecords
        self.onFinished = onFinished
        _model = State(initialValue: OnboardingModel())
    }

    /// Continue the normal plan builder for a home that was started with records only.
    init(addingPlan: Bool, onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
        self.addingPlan = addingPlan
        let model = OnboardingModel()
        model.restore = .ready
        _model = State(initialValue: model)
    }

    /// Previews / tests: start from a prepared model.
    init(model: OnboardingModel, onFinished: @escaping () -> Void = {}) {
        self.onFinished = onFinished
        _model = State(initialValue: model)
    }

    var body: some View {
        Group {
            switch model.restore {
            case .checking:
                OnboardingStatusView(title: "Checking iCloud…", subtitle: "Looking for a home you already set up.")
            case .restoring:
                OnboardingStatusView(title: "Restoring your home…", subtitle: "Your plan is coming down from iCloud.")
            case .ready:
                NavigationStack(path: $model.routes) {
                    Group {
                        if addingPlan || showingPlanSetup {
                            AddressStep(model: model)
                        } else {
                            welcome
                        }
                    }
                        .toolbar {
                            if addingPlan {
                                ToolbarItem(placement: .cancellationAction) { Button("Close") { onFinished() } }
                            } else if showingPlanSetup && model.routes.isEmpty {
                                ToolbarItem(placement: .cancellationAction) { Button("Back") { showingPlanSetup = false } }
                            }
                        }
                        .navigationDestination(for: OnboardingModel.Route.self) { route in
                            destination(route)
                        }
                }
            }
        }
        .task { await model.runRestoreCheck(env, onFinished: onFinished) }
    }

    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "house.and.flag.fill")
                    .font(.system(size: 46)).foregroundStyle(Color.accentColor).accessibilityHidden(true)
                Text("Home Blueprint").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                Text("Keep up with home tasks and keep a record of the work you’ve done.")
                    .font(.title3).foregroundStyle(.secondary)
                Button {
                    Task { await model.startWithRecords(env, onFinished: onFinished) }
                } label: {
                    Label("Start with tasks and projects", systemImage: "checklist").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .accessibilityIdentifier("onboarding.startRecords")
                if let bringRecords {
                    Button {
                        Task { await model.startWithRecords(env, onFinished: bringRecords) }
                    } label: {
                        Label("Bring in existing records", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                    .accessibilityIdentifier("onboarding.bringRecords")
                }
                Button {
                    showingPlanSetup = true
                } label: {
                    Label("Set up my floor plan", systemImage: "square.3.layers.3d").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.large)
                if model.isSaving { ProgressView("Saving your home…") }
                if let error = model.commitError { Text(error).foregroundStyle(.secondary) }
            }
            .disabled(model.isSaving)
            .padding(24).frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func destination(_ route: OnboardingModel.Route) -> some View {
        switch route {
        case .chooser: PathChooser(model: model)
        case .scan: ScanFlow(model: model)
        case .blocks: BlocksFlow(model: model)
        case .trace: TraceFlow(model: model)
        case .rough: RoughFlow(model: model)
        case .review: ReviewDraft(model: model, onFinished: onFinished)
        }
    }
}

/// Full-screen progress used by the restore check.
struct OnboardingStatusView: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// "Step n of 3" header text used by the steps (mockup 6.1).
struct OnboardingStepLabel: View {
    let step: Int
    var body: some View {
        Text("Step \(step) of 3").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
    }
}

#Preview("Onboarding (empty)") {
    OnboardingFlow(onFinished: {}).environment(AppEnvironment.preview(sample: false))
}

#Preview("Restoring") {
    OnboardingStatusView(title: "Restoring your home…", subtitle: "Your plan is coming down from iCloud.")
}

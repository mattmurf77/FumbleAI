import SwiftUI
import HomeCore
import HomeCoreTesting

/// Create / edit a project (FR-PRJ-01…03, AC-PRJ-7/9). Present modally (own NavigationStack):
///
///     ProjectForm(spaceID: room.id, levelID: room.levelId, initialStatus: .idea)   // "+" → Future Project
///     ProjectForm(spaceID: room.id, levelID: room.levelId, initialStatus: .done)   // "+" → Past Work
///     ProjectForm(projectID: project.id)                                          // Edit
///
/// A new Future Project starts as Idea and becomes Planned once an estimate is typed (unless the user picked a
/// status). Past Work (status Done) shows the completed date, actual cost and hours.
struct ProjectForm: View {
    private enum Mode: Equatable { case create(spaceID: UUID?, levelID: UUID?, status: Project.Status), edit(UUID) }

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    private let mode: Mode
    var onSaved: ((Project) -> Void)?

    init(spaceID: UUID?, levelID: UUID?, initialStatus: Project.Status, onSaved: ((Project) -> Void)? = nil) {
        mode = .create(spaceID: spaceID, levelID: levelID, status: initialStatus)
        self.onSaved = onSaved
        _status = State(initialValue: initialStatus == .unknown ? .idea : initialStatus)
    }

    init(projectID: UUID, onSaved: ((Project) -> Void)? = nil) {
        mode = .edit(projectID); self.onSaved = onSaved
    }

    @State private var loaded = false
    @State private var propertyId: UUID?
    @State private var currency = "USD"
    @State private var original: Project?
    @State private var title = ""
    @State private var notes = ""
    @State private var scope: Scope = .property
    @State private var status: Project.Status = .idea
    @State private var statusTouched = false
    @State private var priority: Int?
    @State private var estText = ""
    @State private var estHoursText = ""
    @State private var actualText = ""
    @State private var actualHoursText = ""
    @State private var hasTarget = false
    @State private var targetOn = LocalDate(2026, 1, 1)
    @State private var completedOn = LocalDate(2026, 1, 1)
    @State private var vendor = ""
    @State private var saving = false
    @State private var errorText: String?

    private var isEditing: Bool { if case .edit = mode { return true }; return false }
    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var est: ProjectInput.MoneyResult { ProjectInput.money(estText, currency: currency) }
    private var actual: ProjectInput.MoneyResult { ProjectInput.money(actualText, currency: currency) }

    private var inputsValid: Bool {
        if case .invalid = est { return false }
        if case .invalid = actual { return false }
        return ProjectInput.hours(estHoursText) != nil && ProjectInput.hours(actualHoursText) != nil
    }

    private var canSave: Bool { loaded && !saving && propertyId != nil && !trimmedTitle.isEmpty && inputsValid }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title, e.g. LVP flooring", text: $title)
                    SchedulePlacePicker(propertyId: propertyId, scope: $scope)
                    Picker("Status", selection: Binding(get: { status }, set: { status = $0; statusTouched = true })) {
                        ForEach(Project.Status.lifecycleSteps, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Picker("Priority", selection: $priority) {
                        Text("None").tag(Int?.none)
                        Text("High").tag(Int?.some(1))
                        Text("Medium").tag(Int?.some(2))
                        Text("Low").tag(Int?.some(3))
                    }
                }

                Section("Estimate") {
                    ProjectMoneyField(title: "Cost", text: $estText, currency: currency)
                        .onChange(of: estText) { _, _ in autoPlan() }
                    ProjectHoursField(title: "Hours", text: $estHoursText)
                    Toggle("Target date", isOn: $hasTarget)
                    if hasTarget {
                        DatePicker("Target", selection: $targetOn.scheduleDate(env.clock.calendar), displayedComponents: .date)
                    }
                }

                if status == .done || status == .inProgress || !actualText.isEmpty {
                    Section {
                        if status == .done {
                            DatePicker("Completed", selection: $completedOn.scheduleDate(env.clock.calendar),
                                       in: ...Date(), displayedComponents: .date)
                        }
                        ProjectMoneyField(title: "Actual cost", text: $actualText, currency: currency)
                        ProjectHoursField(title: "Actual hours", text: $actualHoursText)
                    } header: {
                        Text("Actual")
                    } footer: {
                        Text("Leave the actual cost empty to use the sum of the line items.")
                    }
                }

                Section {
                    TextField("Vendor", text: $vendor)
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...6)
                }
            }
            .navigationTitle(isEditing ? "Edit Project" : (status == .done ? "Past Work" : "New Project"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(!canSave) }
            }
            .overlay { if !loaded { ProgressView() } }
            .alert("Couldn’t save", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
        .feedbackPage("Project form")
        .task { await load() }
    }

    /// FR-PRJ-03: Idea → Planned once an estimate is entered (only for new projects whose status wasn't chosen).
    private func autoPlan() {
        guard !isEditing, !statusTouched else { return }
        if case .value(let m) = est, m.cents > 0, status == .idea { status = .planned }
        if case .empty = est, status == .planned { status = .idea }
    }

    @MainActor
    private func load() async {
        guard !loaded else { return }
        let today = env.clock.today
        targetOn = today.adding(days: 30)
        completedOn = today
        guard let property = try? await env.plan.currentProperty() else { loaded = true; return }
        propertyId = property.id
        currency = property.currencyCode
        switch mode {
        case .create(let spaceID, let levelID, _):
            var spaceLevel: UUID?
            if let spaceID { spaceLevel = try? await env.plan.space(spaceID)?.levelId }
            scope = Scope.scheduleDefault(spaceID: spaceID, levelID: levelID, spaceLevel: spaceLevel)
        case .edit(let id):
            guard let p = try? await env.projects.project(id) else { errorText = "This project was deleted."; loaded = true; return }
            original = p
            title = p.title; notes = p.notes ?? ""; scope = p.scope; status = p.status == .unknown ? .idea : p.status
            priority = p.priority; estText = ProjectInput.text(p.estCost); estHoursText = ProjectInput.text(p.estHours)
            actualText = ProjectInput.text(p.actualCost); actualHoursText = ProjectInput.text(p.actualHours)
            hasTarget = p.targetOn != nil; targetOn = p.targetOn ?? targetOn; completedOn = p.completedOn ?? today
            vendor = p.vendor ?? ""; currency = p.currencyCode
            statusTouched = true
        }
        loaded = true
    }

    @MainActor
    private func save() async {
        guard canSave, let propertyId else { return }
        saving = true
        defer { saving = false }
        let estMoney: Money? = { if case .value(let m) = est { return m }; return nil }()
        let actualMoney: Money? = { if case .value(let m) = actual { return m }; return nil }()
        let estHours = ProjectInput.hours(estHoursText) ?? nil
        let actualHours = ProjectInput.hours(actualHoursText) ?? nil
        let notesValue = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let vendorValue = vendor.trimmingCharacters(in: .whitespacesAndNewlines)
        let today = env.clock.today
        do {
            let saved: Project
            if var p = original {
                p.title = trimmedTitle
                p.notes = notesValue.isEmpty ? nil : notesValue
                p.scope = scope
                p.priority = priority
                p.estCost = estMoney
                p.estHours = estHours
                p.actualCost = actualMoney
                p.actualHours = actualHours
                p.targetOn = hasTarget ? targetOn : nil
                p.vendor = vendorValue.isEmpty ? nil : vendorValue
                if p.status != status { p = ProjectLogic.setStatus(p, status, today: today) }
                if status == .done { p.completedOn = completedOn }
                try await env.projects.update(p)
                saved = p
            } else {
                let draft = ProjectDraft(propertyId: propertyId, scope: scope, title: trimmedTitle,
                                         notes: notesValue.isEmpty ? nil : notesValue, status: status, priority: priority,
                                         estCost: estMoney, actualCost: actualMoney, estHours: estHours, actualHours: actualHours,
                                         targetOn: hasTarget ? targetOn : nil, completedOn: status == .done ? completedOn : nil,
                                         vendor: vendorValue.isEmpty ? nil : vendorValue)
                saved = try await env.projects.create(draft)
            }
            onSaved?(saved)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

#Preview("Future project") {
    ProjectForm(spaceID: SampleHome.kitchenId, levelID: SampleHome.firstFloorId, initialStatus: .idea)
        .environment(AppEnvironment.preview())
}

#Preview("Past work") {
    ProjectForm(spaceID: SampleHome.bathId, levelID: SampleHome.secondFloorId, initialStatus: .done)
        .environment(AppEnvironment.preview())
}

#Preview("Edit") {
    ProjectForm(projectID: SampleHome.fridgeProjectId)
        .environment(AppEnvironment.preview())
}

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

    init(spaceID: UUID?, levelID: UUID?, initialStatus: Project.Status, suggestion: MaintenanceIdea? = nil,
         suggestedGuide: HomeContentCatalog.Guide? = nil, onSaved: ((Project) -> Void)? = nil) {
        mode = .create(spaceID: spaceID, levelID: levelID, status: initialStatus)
        self.onSaved = onSaved
        _status = State(initialValue: initialStatus == .unknown ? .idea : initialStatus)
        _title = State(initialValue: suggestion?.title ?? "")
        if let guide = suggestedGuide {
            _notes = State(initialValue: "US professional planning range: " + guide.priceLabel + ". " + guide.scope + " " +
                guide.sources.map { $0.label + " (checked " + $0.reviewedOn + "): " + $0.url.absoluteString }.joined(separator: " "))
        } else if let idea = suggestion, let range = idea.costLabel, let source = idea.priceSource {
            _notes = State(initialValue: "US professional planning range: " + range + ". " + idea.sourceLabel + ". " + source.absoluteString)
        }
    }

    init(projectID: UUID, onSaved: ((Project) -> Void)? = nil) {
        mode = .edit(projectID); self.onSaved = onSaved
    }

    @State private var loaded = false
    @State private var propertyId: UUID?
    @State private var currency = "USD"
    @State private var country: String?
    @State private var estimateChanges: [WorkEstimate] = []
    @State private var original: Project?
    @State private var title = ""
    @State private var notes = ""
    @State private var scope: Scope = .property
    @State private var status: Project.Status = .idea
    @State private var statusTouched = false
    @State private var workAction: Project.WorkAction?
    @State private var priority: Int?
    @State private var estText = ""
    @State private var estHoursText = ""
    @State private var actualText = ""
    @State private var actualHoursText = ""
    @State private var hasTarget = false
    @State private var targetOn = LocalDate(2026, 1, 1)
    private enum CompletionPrecision: Hashable { case unknown, year, day }
    @State private var completionPrecision: CompletionPrecision = .unknown
    @State private var completionYearText = ""
    private var completionYear: Int? {
        guard completionYearText.count == 4, let value = Int(completionYearText), (1...9999).contains(value) else { return nil }
        return value
    }
    @State private var completedOn = LocalDate(2026, 1, 1)
    @State private var vendor = ""
    @State private var saving = false
    @State private var errorText: String?

    private var isEditing: Bool { if case .edit = mode { return true }; return false }
    private var loggingHistory: Bool {
        if case .create(_, _, .done) = mode { return true }
        return false
    }
    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var est: ProjectInput.MoneyResult { ProjectInput.money(estText, currency: currency) }
    private var actual: ProjectInput.MoneyResult { ProjectInput.money(actualText, currency: currency) }

    private var inputsValid: Bool {
        if status == .done, completionPrecision == .year, completionYear == nil { return false }
        if case .invalid = est { return false }
        if case .invalid = actual { return false }
        return ProjectInput.hours(estHoursText) != nil && ProjectInput.hours(actualHoursText) != nil
    }

    private var canSave: Bool { loaded && !saving && propertyId != nil && (!isEditing || original != nil) && !trimmedTitle.isEmpty && inputsValid }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(loggingHistory ? "e.g. Replaced the kitchen windows" : "Title, e.g. LVP flooring", text: $title)
                        .accessibilityLabel(loggingHistory ? "What changed?" : "Project title")
                        .accessibilityIdentifier("project.title")
                    SchedulePlacePicker(propertyId: propertyId, scope: $scope)
                    if !loggingHistory {
                        Picker("Status", selection: Binding(get: { status }, set: { status = $0; statusTouched = true })) {
                            ForEach(Project.Status.lifecycleSteps, id: \.self) { status in Text(status.displayName).tag(status) }
                        }
                        Picker("Priority", selection: $priority) {
                            Text("None").tag(Int?.none)
                            Text("High").tag(Int?.some(1))
                            Text("Medium").tag(Int?.some(2))
                            Text("Low").tag(Int?.some(3))
                        }
                    }
                } header: {
                    if loggingHistory { Text("What changed?") }
                }

                if !loggingHistory {
                    Section("Costs and timing") {
                        if let propertyId {
                            WorkEstimateLink(propertyId: propertyId, currency: currency, country: country, title: trimmedTitle,
                                             owner: original.map { .project($0.id) }, staged: estimateChanges,
                                             stage: { estimateChanges = $0 }, useCostLabel: "Use estimate as project budget",
                                             useCost: { estText = ProjectInput.text($0) })
                        }
                        ProjectMoneyField(title: "Budget", text: $estText, currency: currency)
                            .onChange(of: estText) { _, _ in autoPlan() }
                        ProjectHoursField(title: "Hours", text: $estHoursText)
                        Toggle("Target date", isOn: $hasTarget)
                        if hasTarget {
                            DatePicker("Target", selection: $targetOn.scheduleDate(env.clock.calendar), displayedComponents: .date)
                        }
                    }
                }

                if status == .done || status == .inProgress || !actualText.isEmpty {
                    Section {
                        if status == .done {
                            Picker("Completion date", selection: $completionPrecision) {
                                Text("Unknown").tag(CompletionPrecision.unknown)
                                Text("Year only").tag(CompletionPrecision.year)
                                Text("Exact date").tag(CompletionPrecision.day)
                            }
                            if completionPrecision == .year {
                                TextField("Four-digit completion year", text: $completionYearText)
                                    .keyboardType(.numberPad).accessibilityIdentifier("project.completionYear")
                            } else if completionPrecision == .day {
                                DatePicker("Completed", selection: $completedOn.scheduleDate(env.clock.calendar),
                                           in: ...env.clock.now, displayedComponents: .date)
                            }
                        }
                        ProjectMoneyField(title: "Actual cost", text: $actualText, currency: currency)
                        if !loggingHistory { ProjectHoursField(title: "Actual hours", text: $actualHoursText) }
                    } header: {
                        Text(loggingHistory ? "Details you remember" : "Actual")
                    } footer: {
                        Text(loggingHistory ? "You can leave the date and cost blank. Add a receipt to the saved project whenever you have one." : "Leave the actual cost empty to use the sum of the line items.")
                    }
                }

                Section {
                    if loggingHistory {
                        DisclosureGroup("More details") {
                            ProjectWorkActionPicker(selection: $workAction)
                            TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...6)
                            TextField("Contractor or company", text: $vendor)
                            ProjectHoursField(title: "Actual hours", text: $actualHoursText)
                        }
                    } else {
                        if status == .done { ProjectWorkActionPicker(selection: $workAction) }
                        TextField("Vendor", text: $vendor)
                        TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...6)
                    }
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
        country = property.address?.countryCode
        switch mode {
        case .create(let spaceID, let levelID, _):
            var spaceLevel: UUID?
            if let spaceID { spaceLevel = try? await env.plan.space(spaceID)?.levelId }
            scope = Scope.scheduleDefault(spaceID: spaceID, levelID: levelID, spaceLevel: spaceLevel)
        case .edit(let id):
            guard let p = try? await env.projects.project(id) else { errorText = "This project was deleted."; loaded = true; return }
            original = p
            title = p.title; notes = p.notes ?? ""; scope = p.scope; status = p.status == .unknown ? .idea : p.status
            workAction = p.workAction
            priority = p.priority; estText = ProjectInput.text(p.estCost); estHoursText = ProjectInput.text(p.estHours)
            actualText = ProjectInput.text(p.actualCost); actualHoursText = ProjectInput.text(p.actualHours)
            completionPrecision = p.completedOn != nil ? .day : (p.completedYear != nil ? .year : .unknown)
            completionYearText = p.completedYear.map(String.init) ?? ""
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
                p.workAction = workAction
                p.priority = priority
                p.estCost = estMoney
                p.estHours = estHours
                p.actualCost = actualMoney
                p.actualHours = actualHours
                p.targetOn = hasTarget ? targetOn : nil
                p.vendor = vendorValue.isEmpty ? nil : vendorValue
                if p.status != status { p = ProjectLogic.setStatus(p, status, today: today) }
                if status == .done {
                    p.completedOn = completionPrecision == .day ? completedOn : nil
                    p.completedYear = completionPrecision == .year ? completionYear : nil
                }
                try await env.projects.update(p, estimates: estimateChanges)
                saved = p
            } else {
                let draft = ProjectDraft(propertyId: propertyId, scope: scope, title: trimmedTitle,
                                         notes: notesValue.isEmpty ? nil : notesValue, status: status, workAction: workAction, priority: priority,
                                         estCost: estMoney, actualCost: actualMoney, estHours: estHours, actualHours: actualHours,
                                         targetOn: hasTarget ? targetOn : nil, completedOn: status == .done && completionPrecision == .day ? completedOn : nil,
                                         completedYear: status == .done && completionPrecision == .year ? completionYear : nil,
                                         vendor: vendorValue.isEmpty ? nil : vendorValue)
                saved = try await env.projects.create(draft, estimates: estimateChanges)
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

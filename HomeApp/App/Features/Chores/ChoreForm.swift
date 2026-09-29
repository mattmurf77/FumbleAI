import SwiftUI
import HomeCore
import HomeCoreTesting

/// Create / edit a chore (FR-CHR-01, mockup 4.1). Present modally (it has its own NavigationStack):
///
///     .sheet(isPresented: $adding) { ChoreForm(spaceID: space.id, levelID: space.levelId) }
///     .sheet(item: $editing) { ChoreForm(choreID: $0.id) }
///
/// Reminders replan automatically after the save (DomainEvent → `reminders.replan`); the calendar is enabled /
/// disabled here because a new chore has no id until it's saved.
struct ChoreForm: View {
    private enum Mode: Equatable { case create(spaceID: UUID?, levelID: UUID?), edit(UUID) }

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    private let mode: Mode
    /// Called with the saved chore (after the calendar step).
    var onSaved: ((Chore) -> Void)?

    init(spaceID: UUID?, levelID: UUID?, onSaved: ((Chore) -> Void)? = nil) {
        mode = .create(spaceID: spaceID, levelID: levelID); self.onSaved = onSaved
    }

    init(choreID: UUID, onSaved: ((Chore) -> Void)? = nil) {
        mode = .edit(choreID); self.onSaved = onSaved
    }

    // Form state
    @State private var loaded = false
    @State private var propertyId: UUID?
    @State private var original: Chore?
    @State private var title = ""
    @State private var notes = ""
    @State private var scope: Scope = .property
    @State private var assigneeId: UUID?
    @State private var rule: RepeatRule?
    @State private var startOn = LocalDate(2026, 1, 1)
    @State private var hasTime = false
    @State private var dueMinutes: MinuteOfDay = 19 * 60
    @State private var remindEnabled = false
    @State private var remindOffset = 0
    @State private var calendarOn = false
    @State private var calendarId: String?
    @State private var originalCalendarId: String?
    @State private var linkedThingId: UUID?
    @State private var isPaused = false

    // Lookups
    @State private var people: [Person] = []
    @State private var things: [Thing] = []

    // Save state
    @State private var saving = false
    @State private var saveError: String?
    @State private var calendarFailure: Chore?
    /// The saved chore whose calendar step failed (kept while the alert's binding clears `calendarFailure`).
    @State private var failedChore: Chore?

    private var isEditing: Bool { if case .edit = mode { return true }; return false }
    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        loaded && !saving && propertyId != nil && !trimmedTitle.isEmpty && trimmedTitle.count <= 120 && (!calendarOn || calendarId != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title, e.g. Change HVAC filter", text: $title)
                        .textInputAutocapitalization(.sentences)
                    if trimmedTitle.count > 120 {
                        Text("Keep the title under 120 characters.").font(.footnote).foregroundStyle(.red)
                    }
                    SchedulePlacePicker(propertyId: propertyId, scope: $scope)
                    Picker("Assignee", selection: $assigneeId) {
                        Text("Anyone").tag(UUID?.none)
                        ForEach(people) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                }

                Section("Schedule") {
                    RepeatRulePicker(rule: $rule, startOn: startOn)
                    DatePicker(rule == nil ? "Due" : "Starts", selection: $startOn.scheduleDate(env.clock.calendar),
                               displayedComponents: .date)
                    Toggle("Time of day", isOn: $hasTime)
                    if hasTime {
                        DatePicker("Time", selection: $dueMinutes.scheduleTime(env.clock.calendar), displayedComponents: .hourAndMinute)
                    }
                    if isEditing {
                        Toggle("Paused", isOn: $isPaused)
                    }
                }

                Section("Reminders") {
                    ReminderToggle(isOn: $remindEnabled, offsetMinutes: $remindOffset, dueMinutes: hasTime ? dueMinutes : nil)
                }

                ChoreCalendarSection(choreId: original?.id, rule: rule, isOn: $calendarOn, calendarId: $calendarId)

                Section {
                    Picker("Linked appliance", selection: $linkedThingId) {
                        Text("None").tag(UUID?.none)
                        ForEach(things) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...6)
                } footer: {
                    Text("Link a chore to an appliance to see its filter size or bulb type on the chore.")
                }
            }
            .navigationTitle(isEditing ? "Edit To-Do" : "New To-Do")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(!canSave)
                }
            }
            .disabled(saving)
            .overlay { if !loaded { ProgressView() } }
            .alert("Couldn’t save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(saveError ?? "") }
            .alert("Couldn’t add to calendar", isPresented: Binding(get: { calendarFailure != nil }, set: { if !$0 { calendarFailure = nil } })) {
                Button("Retry") { Task { await retryCalendar() } }
                Button("Not now", role: .cancel) { finish(failedChore) }
            } message: {
                Text("The to-do was saved. You can try adding it to your calendar again.")
            }
        }
        .task { await load() }
    }

    // MARK: Load

    @MainActor
    private func load() async {
        guard !loaded else { return }
        let today = env.clock.today
        startOn = today
        let appSettings = await env.settings.load()
        remindOffset = appSettings.defaultRemindOffsetMin
        guard let property = try? await env.plan.currentProperty() else { loaded = true; return }
        propertyId = property.id
        people = ((try? await env.people.people(property: property.id)) ?? []).sorted { $0.sortOrder < $1.sortOrder }
        things = ((try? await env.things.things(ThingQuery(propertyId: property.id))) ?? [])
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        switch mode {
        case .create(let spaceID, let levelID):
            var spaceLevel: UUID?
            if let spaceID { spaceLevel = try? await env.plan.space(spaceID)?.levelId }
            scope = Scope.scheduleDefault(spaceID: spaceID, levelID: levelID, spaceLevel: spaceLevel)
        case .edit(let id):
            guard let c = try? await env.chores.chore(id) else { saveError = "This to-do was deleted."; loaded = true; return }
            original = c
            title = c.title; notes = c.notes ?? ""; scope = c.scope; assigneeId = c.assigneeId; rule = c.repeatRule
            startOn = c.nextDueOn ?? c.startOn
            if c.repeatRule != nil { startOn = c.startOn }
            hasTime = c.dueMinutes != nil; dueMinutes = c.dueMinutes ?? dueMinutes
            remindEnabled = c.remindEnabled; remindOffset = c.remindOffsetMin
            calendarOn = c.calendarEnabled; linkedThingId = c.linkedThingId; isPaused = c.isPaused
            if let link = try? await env.chores.calendarLink(chore: id) {
                calendarId = link.calendarIdentifier
                originalCalendarId = link.calendarIdentifier
            }
        }
        loaded = true
    }

    // MARK: Save

    @MainActor
    private func save() async {
        guard canSave, let propertyId else { return }
        saving = true
        defer { saving = false }
        let notesValue = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let saved: Chore
            if var c = original {
                let wasCalendarOn = c.calendarEnabled
                c.title = trimmedTitle
                c.notes = notesValue.isEmpty ? nil : notesValue
                c.scope = scope
                c.assigneeId = assigneeId
                c.repeatRule = rule
                if rule != nil { c.startOn = startOn }
                if rule == nil && c.nextDueOn != startOn && c.closedAt == nil {
                    // One-off: the date field is the due date.
                    c.startOn = startOn
                    c.nextDueOn = startOn
                }
                // When the rule or start changed, `ChoreRepository.update` recomputes next_due_on (history is kept).
                c.dueMinutes = hasTime ? dueMinutes : nil
                c.remindEnabled = remindEnabled
                c.remindOffsetMin = remindOffset
                c.linkedThingId = linkedThingId
                c.isPaused = isPaused
                c.calendarEnabled = calendarOn && calendarId != nil
                try await env.chores.update(c)
                saved = (try? await env.chores.chore(c.id)) ?? c
                if wasCalendarOn && !calendarOn {
                    await env.calendar.disable(chore: c.id)
                } else if calendarOn, let calendarId, (!wasCalendarOn || calendarId != originalCalendarId) {
                    do { try await env.calendar.enable(chore: c.id, calendarId: calendarId) } catch {
                        failedChore = saved; calendarFailure = saved; return
                    }
                }
            } else {
                let draft = ChoreDraft(propertyId: propertyId, scope: scope, title: trimmedTitle,
                                       notes: notesValue.isEmpty ? nil : notesValue, assigneeId: assigneeId, repeatRule: rule,
                                       startOn: startOn, dueMinutes: hasTime ? dueMinutes : nil, remindEnabled: remindEnabled,
                                       remindOffsetMin: remindOffset, calendarEnabled: false, linkedThingId: linkedThingId)
                saved = try await env.chores.create(draft)
                if calendarOn, let calendarId {
                    do { try await env.calendar.enable(chore: saved.id, calendarId: calendarId) } catch {
                        failedChore = saved; calendarFailure = saved; return
                    }
                }
            }
            finish(saved)
        } catch {
            saveError = error.localizedDescription
        }
    }

    @MainActor
    private func retryCalendar() async {
        guard let c = failedChore, let calendarId else { return }
        do {
            try await env.calendar.enable(chore: c.id, calendarId: calendarId)
            finish(c)
        } catch {
            calendarFailure = c
        }
    }

    private func finish(_ chore: Chore?) {
        if let chore { onSaved?(chore) }
        dismiss()
    }
}

#Preview("New in Kitchen") {
    ChoreForm(spaceID: SampleHome.kitchenId, levelID: SampleHome.firstFloorId)
        .environment(AppEnvironment.preview())
}

#Preview("Edit filter") {
    ChoreForm(choreID: SampleHome.filterId)
        .environment(AppEnvironment.preview())
}

import SwiftUI
import HomeCore
import HomeCoreTesting

/// Chore detail (mockup 4.1, FR-CHR-20…32): due card with Mark done, skip / reschedule / pause, schedule, reminder and
/// calendar status, linked appliance, history, "Turn into project", delete. Push it inside a NavigationStack:
///
///     NavigationLink(value: chore.id) … .navigationDestination(for: UUID.self) { ChoreDetailView(choreID: $0) }
struct ChoreDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let choreID: UUID

    @State private var chore: Chore?
    @State private var missing = false
    @State private var names = SchedulePlaceNames()
    @State private var people: [UUID: String] = [:]
    @State private var thing: Thing?
    @State private var completions: [ChoreCompletion] = []
    @State private var ownership: CalendarOwnership = .notEnabled
    @State private var notificationStatus: PermissionStatus = .notDetermined

    @State private var editing = false
    @State private var rescheduling = false
    @State private var rescheduleDate = LocalDate(2026, 1, 1)
    @State private var confirmDelete = false
    @State private var spawnedProject: ProjectRoute?
    @State private var undo: UndoState?
    @State private var doneFeedback = 0
    @State private var errorText: String?

    private struct UndoState: Equatable { var message: String; var previousDue: LocalDate?; var token = UUID() }
    struct ProjectRoute: Identifiable, Hashable { let id: UUID }

    private var today: LocalDate { env.clock.today }

    var body: some View {
        Group {
            if let chore {
                content(chore)
            } else if missing {
                ContentUnavailableView("To-do not found", systemImage: "checklist", description: Text("It may have been deleted."))
            } else {
                ProgressView()
            }
        }
        .feedbackPage("Chore details")
        .navigationTitle(chore.map { names.name($0.scope) } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if chore != nil {
                ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = true } }
            }
        }
        .sheet(isPresented: $editing) { ChoreForm(choreID: choreID) }
        .sheet(isPresented: $rescheduling) { rescheduleSheet }
        .navigationDestination(item: $spawnedProject) { ProjectDetailView(projectID: $0.id) }
        .confirmationDialog("Delete this to-do?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: {
            Text("It moves to Recently Deleted for 30 days. Future calendar events are removed; past ones stay.")
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
        .sensoryFeedback(.success, trigger: doneFeedback)
        .overlay(alignment: .bottom) { undoBar }
        .task { await observe() }
        .task(id: chore?.updatedAt) { await loadExtras() }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ c: Chore) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(c.title).font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        ScheduleTag(text: names.path(c.scope), systemImage: "mappin")
                        if let thing { ScheduleTag(text: thing.name, systemImage: "link", accent: true) }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
            }

            Section { dueCard(c) }

            Section("Schedule") {
                LabeledContent("Repeat", value: c.repeatRule?.humanText ?? "Doesn't repeat")
                LabeledContent("Assignee", value: c.assigneeId.flatMap { people[$0] } ?? "Anyone")
                if c.isRecurring { LabeledContent("Started", value: ScheduleFormat.longDay(c.startOn)) }
                if let m = c.dueMinutes { LabeledContent("Time", value: ScheduleFormat.time(m)) }
                else { LabeledContent("Time", value: "All day") }
            }

            Section("Reminders") {
                if c.remindEnabled {
                    Label(reminderText(c), systemImage: "bell")
                    if notificationStatus == .denied {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Notifications are off for Home").foregroundStyle(.orange)
                            ScheduleSettingsLink()
                        }.font(.footnote)
                    }
                } else {
                    Label("No reminder", systemImage: "bell.slash").foregroundStyle(.secondary)
                }
            }

            Section("Calendar") {
                switch ownership {
                case .notEnabled:
                    Label(c.calendarEnabled ? "Adding to calendar…" : "Not in a calendar", systemImage: "calendar")
                        .foregroundStyle(.secondary)
                case .ownedByThisDevice(let calendar):
                    Label("In “\(calendar)” · \(c.repeatRule?.anchor == .schedule ? "repeating event" : "one event")", systemImage: "calendar")
                case .ownedByOtherDevice(let nickname):
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Calendar events are managed on ‘\(nickname)’", systemImage: "iphone")
                        Button("Manage from this iPhone") { Task { await adopt() } }
                    }
                }
            }

            if let thing, !thingSpecs(thing).isEmpty {
                Section(thing.name) {
                    ForEach(thingSpecs(thing)) { LabeledContent($0.label, value: $0.value) }
                }
            }

            if let notes = c.notes, !notes.isEmpty {
                Section("Notes") { Text(notes) }
            }

            Section("History") {
                if completions.isEmpty {
                    Text("Not done yet").foregroundStyle(.secondary)
                } else {
                    ForEach(completions) { h in
                        HStack {
                            Image(systemName: h.outcome == .skipped ? "forward.end" : "checkmark.circle.fill")
                                .foregroundStyle(h.outcome == .skipped ? Color.secondary : Color.green)
                            VStack(alignment: .leading) {
                                Text(h.outcome == .skipped ? "Skipped" : "Done")
                                Text([ScheduleFormat.longDay(h.doneOn), h.doneBy.flatMap { people[$0] }].compactMap { $0 }.joined(separator: " · "))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let due = h.dueOn, due != h.doneOn {
                                Text("due \(ScheduleFormat.day(due, today: today))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            Section {
                Button { Task { await turnIntoProject() } } label: { Label("Turn into project", systemImage: "hammer") }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete to-do", systemImage: "trash") }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func dueCard(_ c: Chore) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ScheduleFormat.due(c, today: today)).font(.headline)
                        .foregroundStyle(c.isOverdue(today: today) ? Color.red : Color.primary)
                    Text(dueSubtitle(c)).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if c.isOpen {
                    Button { Task { await act(.done) } } label: { Label("Mark done", systemImage: "checkmark") }
                        .buttonStyle(.borderedProminent)
                }
            }
            if c.closedAt == nil {
                HStack(spacing: 12) {
                    if c.isOpen && c.isRecurring {
                        Button("Skip") { Task { await act(.skipped) } }
                    }
                    Button("Reschedule…") {
                        rescheduleDate = c.nextDueOn ?? today
                        rescheduling = true
                    }
                    Button(c.isPaused ? "Resume" : "Pause") { Task { await setPaused(!c.isPaused) } }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private func dueSubtitle(_ c: Chore) -> String {
        var parts: [String] = []
        if let d = c.nextDueOn, c.isOpen { parts.append(ScheduleFormat.relative(d, today: today).lowercased()) }
        if let last = completions.first(where: { $0.outcome == .done }) {
            parts.append("last done \(ScheduleFormat.day(last.doneOn, today: today))")
        } else {
            parts.append("never done")
        }
        return parts.joined(separator: " · ")
    }

    private func reminderText(_ c: Chore) -> String {
        let time = c.dueMinutes.map { ScheduleFormat.time($0) } ?? "the default time"
        let offset = c.remindOffsetMin == 0 ? "" : ", \(ScheduleFormat.offsetLabel(c.remindOffsetMin).lowercased())"
        return "On the due day at \(time)\(offset)"
    }

    private struct Spec: Identifiable { var label: String; var value: String; var id: String { label } }

    /// Relevant thing specs (filter size, bulb base…): the template fields that have values.
    private func thingSpecs(_ t: Thing) -> [Spec] {
        let template = ThingTemplate.catalog.first { $0.key == t.templateKey }
        var out: [Spec] = []
        for (key, value) in t.attributes.sorted(by: { $0.key < $1.key }) {
            let text = value.displayText
            guard !text.isEmpty else { continue }
            let label = template?.fields.first { $0.key == key }?.label ?? key
            out.append(Spec(label: label, value: text))
        }
        return Array(out.prefix(4))
    }

    private var rescheduleSheet: some View {
        NavigationStack {
            Form {
                DatePicker("Next due", selection: $rescheduleDate.scheduleDate(env.clock.calendar), displayedComponents: .date)
                    .datePickerStyle(.graphical)
            }
            .navigationTitle("Reschedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { rescheduling = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await reschedule(rescheduleDate); rescheduling = false } }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var undoBar: some View {
        if let undo {
            HStack {
                Text(undo.message).foregroundStyle(.white)
                Spacer()
                Button("Undo") { Task { await performUndo(undo) } }
                    .foregroundStyle(.yellow)
                    .bold()
            }
            .padding()
            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
            .padding()
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: undo.token) {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if self.undo?.token == undo.token { withAnimation { self.undo = nil } }
            }
        }
    }

    // MARK: Data

    @MainActor
    private func observe() async {
        guard let property = try? await env.plan.currentProperty() else { missing = true; return }
        names = await SchedulePlaceNames.load(env, property: property.id)
        let list = (try? await env.people.people(property: property.id)) ?? []
        people = Dictionary(list.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        for await all in env.chores.observeChores(ChoreQuery(propertyId: property.id, includeClosed: true, includePaused: true)) {
            if let c = all.first(where: { $0.id == choreID }) {
                chore = c
                missing = false
            } else {
                chore = nil
                missing = true
            }
        }
    }

    @MainActor
    private func loadExtras() async {
        completions = ((try? await env.chores.completions(chore: choreID)) ?? [])
            .filter { $0.deletedAt == nil }
            .sorted { $0.doneAt > $1.doneAt }
        thing = nil
        if let tid = chore?.linkedThingId { thing = try? await env.things.thing(tid) }
        ownership = await env.calendar.ownership(chore: choreID)
        notificationStatus = await env.notificationAuth.authorizationStatus()
    }

    @MainActor
    private func act(_ outcome: ChoreCompletion.Outcome) async {
        guard let c = chore else { return }
        let previous = c.nextDueOn
        do {
            if outcome == .done {
                // Done in-app defaults to the assignee (FR-CHR-21).
                _ = try await env.chores.complete(c.id, by: c.assigneeId, at: env.clock.now)
                doneFeedback += 1
            } else {
                try await env.chores.skip(c.id, at: env.clock.now)
            }
            withAnimation { undo = UndoState(message: outcome == .done ? "Marked done" : "Skipped", previousDue: previous) }
            await loadExtras()
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Restores the previous due date. NOTE: `ChoreRepository` has no "delete completion" call yet, so the
    /// completion row stays in history (see INTEGRATION_NOTES/schedule.md).
    @MainActor
    private func performUndo(_ state: UndoState) async {
        withAnimation { undo = nil }
        guard let due = state.previousDue else { return }
        do { try await env.chores.reschedule(choreID, to: due) } catch { errorText = error.localizedDescription }
    }

    @MainActor
    private func reschedule(_ d: LocalDate) async {
        do { try await env.chores.reschedule(choreID, to: d) } catch { errorText = error.localizedDescription }
    }

    @MainActor
    private func setPaused(_ paused: Bool) async {
        do { try await env.chores.setPaused(choreID, paused) } catch { errorText = error.localizedDescription }
    }

    @MainActor
    private func turnIntoProject() async {
        do {
            let p = try await env.chores.turnIntoProject(choreID)
            spawnedProject = ProjectRoute(id: p.id)
        } catch { errorText = error.localizedDescription }
    }

    @MainActor
    private func adopt() async {
        do {
            if await env.calendar.authorizationStatus() == .notDetermined { _ = try await env.calendar.requestAccess() }
            try await env.calendar.adoptOwnership(chore: choreID)
            ownership = await env.calendar.ownership(chore: choreID)
        } catch { errorText = "Couldn’t move the calendar events. Check calendar access in Settings." }
    }

    @MainActor
    private func delete() async {
        do {
            try await env.chores.delete(choreID)
            dismiss()
        } catch { errorText = error.localizedDescription }
    }
}

/// Small rounded tag ("Basement · Utility", "🔗 Furnace").
struct ScheduleTag: View {
    let text: String
    var systemImage: String?
    var accent = false
    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.caption2) }
            Text(text).font(.footnote)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background((accent ? Color.accentColor : Color.secondary).opacity(0.15), in: Capsule())
        .foregroundStyle(accent ? Color.accentColor : Color.primary)
    }
}

#Preview {
    NavigationStack { ChoreDetailView(choreID: SampleHome.filterId) }
        .environment(AppEnvironment.preview())
}

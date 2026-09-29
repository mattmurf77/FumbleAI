import SwiftUI
import HomeCore
import HomeCoreTesting

/// To-Dos as a list (spec 04 "To-Dos view", also the list form of the lens): Overdue / Today / This week / Later
/// (+ No date, Paused). Swipe to mark done or skip, tap for detail, "+" to add, filter by housemate (FR-CHR-61).
/// Push it inside a NavigationStack. Optional filters restrict it to one room / floor / whole house.
struct ToDosListView: View {
    @Environment(AppEnvironment.self) private var env
    /// nil = every chore in the home. Same semantics as `ChoreQuery.scope`.
    var scope: Scope?
    /// Everything on a level (rooms + floor-wide).
    var levelID: UUID?
    var title = "To-Dos"

    @State private var chores: [Chore] = []
    @State private var loaded = false
    @State private var names = SchedulePlaceNames()
    @State private var people: [Person] = []
    @State private var personFilter: UUID?
    @State private var adding = false
    @State private var doneFeedback = 0
    @State private var errorText: String?

    private var today: LocalDate { env.clock.today }

    private struct Bucket: Identifiable { let id: String; let title: String; let chores: [Chore] }

    private var buckets: [Bucket] {
        let visible = chores.filter { c in personFilter.map { c.assigneeId == $0 } ?? true }
        let open = visible.filter { $0.closedAt == nil && $0.deletedAt == nil }
        let active = open.filter { !$0.isPaused }
        func sorted(_ a: [Chore]) -> [Chore] {
            a.sorted { ($0.nextDueOn ?? .init(9999, 12, 31), $0.dueMinutes ?? -1, $0.title) < ($1.nextDueOn ?? .init(9999, 12, 31), $1.dueMinutes ?? -1, $1.title) }
        }
        let week = today.adding(days: 6)
        let raw: [Bucket] = [
            Bucket(id: "overdue", title: "Overdue", chores: sorted(active.filter { $0.isOverdue(today: today) })),
            Bucket(id: "today", title: "Today", chores: sorted(active.filter { $0.nextDueOn == today })),
            Bucket(id: "week", title: "This week", chores: sorted(active.filter { ($0.nextDueOn.map { $0 > today && $0 <= week }) ?? false })),
            Bucket(id: "later", title: "Later", chores: sorted(active.filter { ($0.nextDueOn.map { $0 > week }) ?? false })),
            Bucket(id: "nodate", title: "No date", chores: sorted(active.filter { $0.nextDueOn == nil })),
            Bucket(id: "paused", title: "Paused", chores: sorted(open.filter(\.isPaused))),
        ]
        return raw.filter { !$0.chores.isEmpty }
    }

    private var summary: String {
        let active = chores.filter { chore in chore.isOpen && (personFilter.map { p in chore.assigneeId == p } ?? true) }
        let dueWeek = active.filter { $0.isDueThisWeek(today: today) }.count
        let overdue = active.filter { $0.isOverdue(today: today) }.count
        if dueWeek == 0 && overdue == 0 { return "Nothing due this week" }
        return "\(dueWeek) due this week · \(overdue) overdue"
    }

    var body: some View {
        List {
            if loaded && !chores.isEmpty {
                Section { Text(summary).font(.subheadline).foregroundStyle(.secondary) }
            }
            ForEach(buckets) { bucket in
                Section {
                    ForEach(bucket.chores) { c in
                        NavigationLink {
                            ChoreDetailView(choreID: c.id)
                        } label: {
                            ChoreRow(chore: c, today: today, place: scope == nil ? names.name(c.scope) : nil,
                                     assignee: c.assigneeId.flatMap { id in people.first { $0.id == id }?.name },
                                     onComplete: completeAction(c))
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if c.isOpen {
                                Button { Task { await complete(c) } } label: { Label("Done", systemImage: "checkmark") }
                                    .tint(.green)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            if c.isOpen && c.isRecurring {
                                Button { Task { await skip(c) } } label: { Label("Skip", systemImage: "forward.end") }
                                    .tint(.orange)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(bucket.title)
                        Spacer()
                        Text("\(bucket.chores.count)")
                    }
                    .foregroundStyle(bucket.id == "overdue" ? Color.red : Color.secondary)
                }
            }
        }
        .overlay {
            if !loaded {
                ProgressView()
            } else if chores.filter({ $0.closedAt == nil }).isEmpty {
                ContentUnavailableView {
                    Label("No chores yet", systemImage: "checklist")
                } description: {
                    Text("Tap + in a room to add one.")
                } actions: {
                    Button("Add a to-do") { adding = true }.buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !people.isEmpty {
                    Menu {
                        Picker("Show", selection: $personFilter) {
                            Text("Everyone").tag(UUID?.none)
                            ForEach(people) { Text("\($0.name)’s chores").tag(UUID?.some($0.id)) }
                        }
                    } label: {
                        Label(personFilter.flatMap { id in people.first { $0.id == id }?.name } ?? "Everyone",
                              systemImage: "person.crop.circle")
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Label("Add to-do", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $adding) {
            ChoreForm(spaceID: scope?.spaceId, levelID: scope?.levelId ?? levelID)
        }
        .sensoryFeedback(.success, trigger: doneFeedback)
        .alert("Something went wrong", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
        .task { await observe() }
    }

    private func completeAction(_ c: Chore) -> (() -> Void)? {
        guard c.isOpen else { return nil }
        return { Task { await complete(c) } }
    }

    @MainActor
    private func observe() async {
        guard let property = try? await env.plan.currentProperty() else { loaded = true; return }
        names = await SchedulePlaceNames.load(env, property: property.id)
        people = ((try? await env.people.people(property: property.id)) ?? []).sorted { $0.sortOrder < $1.sortOrder }
        let query = ChoreQuery(propertyId: property.id, scope: scope, levelId: levelID, includeClosed: false, includePaused: true)
        for await list in env.chores.observeChores(query) {
            chores = list
            loaded = true
        }
    }

    @MainActor
    private func complete(_ c: Chore) async {
        do {
            _ = try await env.chores.complete(c.id, by: c.assigneeId, at: env.clock.now)
            doneFeedback += 1
        } catch { errorText = error.localizedDescription }
    }

    @MainActor
    private func skip(_ c: Chore) async {
        do { try await env.chores.skip(c.id, at: env.clock.now) } catch { errorText = error.localizedDescription }
    }
}

#Preview("Whole home") {
    NavigationStack { ToDosListView() }
        .environment(AppEnvironment.preview())
}

#Preview("Kitchen") {
    NavigationStack { ToDosListView(scope: .space(SampleHome.kitchenId, level: SampleHome.firstFloorId), title: "Kitchen") }
        .environment(AppEnvironment.preview())
}

#Preview("Empty") {
    NavigationStack { ToDosListView() }
        .environment(AppEnvironment.preview(sample: false))
}

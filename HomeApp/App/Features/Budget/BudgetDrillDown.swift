import SwiftUI
import HomeCore
import HomeCoreTesting

/// Budget drill-down (FR-PRJ-39, LLD §8): per-floor rows, a Whole house row and the total; each shows Planned, Ideas,
/// Spent, Remaining, Variance and Hours. Tap a floor → its rooms (+ floor-wide); tap a room → its projects.
/// Everything comes from `RollupService` (never stored). Push inside a NavigationStack.
struct BudgetDrillDown: View {
    @Environment(AppEnvironment.self) private var env
    @State private var rollup: PropertyRollup?
    @State private var propertyId: UUID?
    @State private var loaded = false

    var body: some View {
        List {
            if let rollup {
                Section {
                    BudgetRollupSummary(rollup: rollup.total, emphasized: true)
                } header: {
                    Text("Home")
                } footer: {
                    if rollup.total.isEmpty { Text("No projects yet — tap + in a room to add one.") }
                }
                Section("Floors") {
                    ForEach(rollup.levels) { row in
                        NavigationLink {
                            BudgetFloorView(levelID: row.levelId, levelName: row.levelName)
                        } label: {
                            BudgetRow(title: row.levelName, rollup: row.rollup)
                        }
                    }
                    NavigationLink {
                        BudgetProjectsList(scope: .property, title: "Whole house")
                    } label: {
                        BudgetRow(title: "Whole house", rollup: rollup.wholeHouse)
                    }
                }
            }
        }
        .feedbackPage("Budget")
        .overlay {
            if !loaded { ProgressView() }
            else if rollup == nil {
                ContentUnavailableView("No home yet", systemImage: "house", description: Text("Create your plan first."))
            }
        }
        .navigationTitle("Budget")
        .task { await observe() }
    }

    @MainActor
    private func observe() async {
        guard let property = try? await env.plan.currentProperty() else { loaded = true; return }
        propertyId = property.id
        for await r in env.rollups.observeProperty(property.id) {
            rollup = r
            loaded = true
        }
    }
}

/// One floor: rooms with activity, the floor-wide row and the floor total.
struct BudgetFloorView: View {
    @Environment(AppEnvironment.self) private var env
    let levelID: UUID
    let levelName: String

    @State private var floor: FloorRollup?
    @State private var rooms: [UUID: Rollup] = [:]
    @State private var spaces: [Space] = []

    private var roomRows: [Space] {
        spaces.filter { rooms[$0.id] != nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private var quietRooms: [Space] {
        spaces.filter { rooms[$0.id] == nil }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            if let floor {
                Section(levelName) { BudgetRollupSummary(rollup: floor.total, emphasized: true) }
            }
            Section("Rooms") {
                ForEach(roomRows) { space in
                    NavigationLink {
                        BudgetProjectsList(scope: .space(space.id, level: levelID), title: space.name)
                    } label: {
                        BudgetRow(title: space.name, rollup: rooms[space.id] ?? .zero)
                    }
                }
                if let floor {
                    NavigationLink {
                        BudgetProjectsList(scope: .level(levelID), title: "\(levelName) (whole floor)")
                    } label: {
                        BudgetRow(title: "Whole floor", rollup: floor.floorWide)
                    }
                }
                if roomRows.isEmpty && (floor?.floorWide.isEmpty ?? true) {
                    Text("No projects on this floor yet").foregroundStyle(.secondary)
                }
            }
            if !quietRooms.isEmpty {
                Section("No projects") {
                    ForEach(quietRooms) { space in
                        NavigationLink {
                            BudgetProjectsList(scope: .space(space.id, level: levelID), title: space.name)
                        } label: {
                            Text(space.name).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .feedbackPage("Budget · " + levelName)
        .navigationTitle(levelName)
        .task { await observeFloor() }
        .task { await observeRooms() }
        .task { spaces = ((try? await env.plan.geometry(level: levelID))?.spaces ?? []).filter { $0.deletedAt == nil } }
    }

    @MainActor private func observeFloor() async { for await f in env.rollups.observeFloor(level: levelID) { floor = f } }
    @MainActor private func observeRooms() async { for await r in env.rollups.observeRooms(level: levelID) { rooms = r } }
}

/// Projects in one scope (a room, a floor's floor-wide projects, or whole house) with planned vs spent per project.
struct BudgetProjectsList: View {
    @Environment(AppEnvironment.self) private var env
    let scope: Scope
    let title: String

    @State private var projects: [Project] = []
    @State private var lineItems: [CostLineItem] = []
    @State private var loaded = false
    @State private var adding = false

    var body: some View {
        List {
            if !projects.isEmpty {
                Section {
                    BudgetRollupSummary(rollup: RollupMath.rollup(projects, lineItems: lineItems,
                                                                  currency: projects.first?.currencyCode ?? "USD"))
                }
            }
            ForEach(Project.Status.lifecycleSteps, id: \.self) { status in
                let group = projects.filter { $0.status == status }
                if !group.isEmpty {
                    Section(status.displayName) {
                        ForEach(group) { p in
                            NavigationLink {
                                ProjectDetailView(projectID: p.id)
                            } label: {
                                projectRow(p)
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if loaded && projects.isEmpty {
                ContentUnavailableView {
                    Label("No projects", systemImage: "hammer")
                } description: {
                    Text("Add a Future Project or log Past Work here.")
                } actions: {
                    Button("Add a project") { adding = true }.buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button { adding = true } label: { Label("Add project", systemImage: "plus") } }
        }
        .sheet(isPresented: $adding) {
            ProjectForm(spaceID: scope.spaceId, levelID: scope.levelId, initialStatus: .idea)
        }
        .task { await observe() }
    }

    private func projectRow(_ p: Project) -> some View {
        let s = RollupMath.spentCents(p, lineItems: lineItems)
        let currency = p.currencyCode
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title)
                Text(p.estCost.map { "Estimate \($0.formatted(showCents: false))" } ?? "No estimate")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if p.status == .inProgress || p.status == .done || s > 0 {
                    Text(Money(cents: s, currency: currency).formatted(showCents: false))
                    if p.status == .done, let est = p.estCost {
                        Text(ScheduleFormat.variance(s - est.cents, currency: currency))
                            .font(.caption).foregroundStyle(s > est.cents ? Color.red : Color.green)
                    } else {
                        Text("spent").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @MainActor
    private func observe() async {
        guard let property = try? await env.plan.currentProperty() else { loaded = true; return }
        for await list in env.projects.observeProjects(ProjectQuery(propertyId: property.id, scope: scope)) {
            projects = list.filter { $0.deletedAt == nil }
            var items: [CostLineItem] = []
            for p in projects { items += (try? await env.projects.lineItems(project: p.id)) ?? [] }
            lineItems = items
            loaded = true
        }
    }
}

/// A navigable row: title + "planned / spent" and remaining.
struct BudgetRow: View {
    let title: String
    let rollup: Rollup

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(rollup.planned.compact) / \(rollup.spent.compact)").monospacedDigit()
                Text("planned / spent").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): planned \(rollup.planned.formatted(showCents: false)), spent \(rollup.spent.formatted(showCents: false))")
    }

    private var detail: String {
        var parts: [String] = []
        if rollup.openCount > 0 { parts.append("\(rollup.openCount) open") }
        if rollup.ideaCount > 0 { parts.append("\(rollup.ideaCount) idea\(rollup.ideaCount == 1 ? "" : "s")") }
        if rollup.doneCount > 0 { parts.append("\(rollup.doneCount) done") }
        return parts.isEmpty ? "No projects" : parts.joined(separator: " · ")
    }
}

/// Planned, Ideas, Spent, Remaining, Variance, Hours (LLD §8.1 definitions; ideas are never added to planned).
struct BudgetRollupSummary: View {
    let rollup: Rollup
    var emphasized = false

    private let columns = [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading),
                           GridItem(.flexible(), alignment: .leading)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            metric("Planned", rollup.planned.formatted(showCents: false))
            metric("Spent", rollup.spent.formatted(showCents: false), accent: true)
            metric("Remaining", rollup.remaining.formatted(showCents: false))
            metric("Ideas", rollup.ideas.formatted(showCents: false), muted: true)
            metric("Variance", rollup.doneCount == 0 ? "—" : ScheduleFormat.variance(rollup.varianceCents, currency: rollup.currency),
                   warn: rollup.varianceCents > 0)
            metric("Hours", hoursText)
        }
        .padding(.vertical, emphasized ? 6 : 2)
    }

    private var hoursText: String {
        let planned = ScheduleFormat.hours(rollup.plannedHours) ?? "0 h"
        let spent = ScheduleFormat.hours(rollup.spentHours) ?? "0 h"
        return "\(planned) / \(spent)"
    }

    private func metric(_ label: String, _ value: String, accent: Bool = false, muted: Bool = false, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(emphasized ? .headline : .subheadline)
                .monospacedDigit()
                .foregroundStyle(warn ? Color.red : (accent ? Color.accentColor : (muted ? Color.secondary : Color.primary)))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Home") {
    NavigationStack { BudgetDrillDown() }
        .environment(AppEnvironment.preview())
}

#Preview("Floor") {
    NavigationStack { BudgetFloorView(levelID: SampleHome.firstFloorId, levelName: "1st Floor") }
        .environment(AppEnvironment.preview())
}

#Preview("Empty") {
    NavigationStack { BudgetDrillDown() }
        .environment(AppEnvironment.preview(sample: false))
}

import SwiftUI
import HomeCore

/// The owner's scheduled work, separate from Home's single recommendation.
struct HomePeriodTasks: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dynamicTypeSize) private var typeSize
    let propertyID: UUID

    @State private var period: HomeTaskPeriod = .day
    @State private var chores: [Chore] = []
    @State private var loaded = false
    @State private var completing: Set<UUID> = []
    @State private var problem: String?

    var body: some View {
        TimelineView(.everyMinute) { _ in
            let today = env.clock.today
            let tasks = period.tasks(chores, today: today, calendar: env.clock.calendar)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Things to do").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("home.periodTasks")
                    Spacer()
                    NavigationLink("See all") { ToDosListView(initialPeriod: period) }
                        .font(.subheadline).frame(minHeight: 44)
                        .accessibilityLabel("See all scheduled tasks")
                        .accessibilityIdentifier("home.period.seeAll")
                }
                if typeSize.isAccessibilitySize {
                    periodPicker.pickerStyle(.menu)
                } else { periodPicker.pickerStyle(.segmented) }
                if !loaded {
                    ProgressView("Loading tasks")
                } else {
                    if !tasks.overdue.isEmpty {
                        Label("\(tasks.overdue.count) overdue", systemImage: "clock.badge.exclamationmark")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .accessibilityHint("See all scheduled tasks to review overdue work")
                    }
                    if tasks.due.isEmpty {
                        Text(period == .day ? "Nothing due today." : "Nothing due this " + period.rawValue + ".")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text(period.dueLabel).font(.subheadline.weight(.semibold))
                        ForEach(tasks.due.prefix(3)) { chore in
                            HStack(spacing: 8) {
                                Button {
                                    Task { await complete(chore) }
                                } label: {
                                    Image(systemName: "circle").font(.title3).frame(width: 44, height: 44)
                                }.buttonStyle(.plain).disabled(completing.contains(chore.id))
                                .accessibilityLabel("Mark " + chore.title + " done")
                                .accessibilityIdentifier("home.period.complete." + chore.id.uuidString)
                                NavigationLink {
                                    ChoreDetailView(choreID: chore.id)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(chore.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                                            Text(ScheduleFormat.due(chore, today: today)).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                    }.contentShape(Rectangle())
                                }.frame(minHeight: 44).accessibilityElement(children: .combine)
                                .accessibilityIdentifier("home.period.open." + chore.id.uuidString)
                            }
                        }
                    }
                }
            }
        }
        .task(id: propertyID) {
            loaded = false
            for await list in env.chores.observeChores(.init(propertyId: propertyID, includePaused: false)) {
                guard !Task.isCancelled else { return }
                chores = list; loaded = true
            }
        }
        .alert("Couldn’t complete task", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") {}
        } message: { Text(problem ?? "") }
    }

    private var periodPicker: some View {
        Picker("Time period", selection: $period) {
            ForEach(HomeTaskPeriod.allCases) { choice in Text(choice.label).tag(choice) }
        }.accessibilityIdentifier("home.period.picker")
    }

    @MainActor private func complete(_ chore: Chore) async {
        guard completing.insert(chore.id).inserted else { return }
        defer { completing.remove(chore.id) }
        do {
            _ = try await env.chores.complete(chore.id, by: chore.assigneeId, at: env.clock.now)
        } catch { problem = error.localizedDescription }
    }
}

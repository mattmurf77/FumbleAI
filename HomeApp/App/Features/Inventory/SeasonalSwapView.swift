import SwiftUI
import HomeCore
import HomeCoreTesting

/// Seasonal swap (spec 08 FR-INV-31..33, LLD §11.4, mockup 5.2). "Get out" = stored clothing of the upcoming
/// season; "Put away" = in-rotation clothing of the other season. Grouped by owner → room › spot path, filter by
/// housemate, swap per item / per spot / all; after putting items away, offers "Move put-away items to a spot…".
/// The upcoming season comes from the date + hemisphere (repository); the segmented control overrides it.
/// Pushable (no own `NavigationStack`).
struct SeasonalSwapView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var property: Property?
    @State private var people: [Person] = []
    @State private var swap: SeasonalSwap?
    /// Season the user picked instead of the computed one (nil = computed).
    @State private var seasonOverride: Season?
    /// Housemate name filter (SwapLine carries owner names).
    @State private var ownerFilter: String?
    @State private var moveIds: [UUID] = []
    @State private var offerMove = false
    @State private var showMove = false
    @State private var errorText: String?

    private var today: LocalDate { env.clock.today }
    private var naturalSeason: Season { Season.upcoming(on: today, latitude: property?.latitude) }
    /// Six months later flips the repository's "upcoming" season.
    private var queryDate: LocalDate {
        guard let o = seasonOverride, o != naturalSeason else { return today }
        return today.adding(months: 6)
    }
    private var shownSeason: Season { swap?.upcoming ?? seasonOverride ?? naturalSeason }
    private var getOut: [TIK.SwapGroup] { TIK.swapGroups(swap?.getOut ?? [], ownerFilter: ownerFilter) }
    private var putAway: [TIK.SwapGroup] { TIK.swapGroups(swap?.putAway ?? [], ownerFilter: ownerFilter) }
    private var taskKey: String { "\(property?.id.uuidString ?? "-")|\(queryDate)" }

    var body: some View {
        List {
            Section {
                Picker("Season", selection: Binding(get: { shownSeason }, set: { seasonOverride = $0 })) {
                    Text("Summer").tag(Season.summer)
                    Text("Winter").tag(Season.winter)
                }
                .pickerStyle(.segmented)
                if !people.isEmpty {
                    Picker("Housemate", selection: $ownerFilter) {
                        Text("Everyone").tag(String?.none)
                        ForEach(people) { p in Text(p.name).tag(String?.some(p.name)) }
                    }
                    .pickerStyle(.menu)
                }
            } footer: {
                Text("\(TIK.seasonTitle(shownSeason.opposite)) → \(TIK.seasonTitle(shownSeason)). Swapping changes In rotation / Stored; items keep their location.")
            }

            if !getOut.isEmpty {
                groupSections(getOut, title: "Get out · \(TIK.seasonTitle(shownSeason))", inRotation: true, verb: "Get out")
            }
            if !putAway.isEmpty {
                groupSections(putAway, title: "Put away · \(TIK.seasonTitle(shownSeason.opposite))", inRotation: false, verb: "Put away")
            }
        }
        .feedbackPage("Seasonal swap")
        .navigationTitle("Seasonal swap")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Swap all") { Task { await swapAll() } }
                    .disabled(getOut.isEmpty && putAway.isEmpty)
            }
        }
        .overlay {
            if swap != nil && getOut.isEmpty && putAway.isEmpty {
                ContentUnavailableView("Nothing to swap for \(TIK.seasonTitle(shownSeason))", systemImage: "arrow.triangle.2.circlepath",
                                       description: Text("Mark clothing as Stored or In rotation to use this."))
            }
        }
        .confirmationDialog("Move put-away items to a spot?", isPresented: $offerMove, titleVisibility: .visible) {
            Button("Choose a spot…") { showMove = true }
            Button("Leave them where they are", role: .cancel) {}
        }
        .sheet(isPresented: $showMove) {
            TIK.MoveItemsSheet(itemIds: moveIds, title: "Put away in…")
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .task {
            property = try? await env.plan.currentProperty()
            if let pid = property?.id {
                people = ((try? await env.people.people(property: pid)) ?? []).sorted { $0.sortOrder < $1.sortOrder }
            }
        }
        .task(id: taskKey) {
            guard let pid = property?.id else { return }
            for await s in env.inventory.observeSeasonalSwap(property: pid, on: queryDate) { swap = s }
        }
    }

    @ViewBuilder
    private func groupSections(_ groups: [TIK.SwapGroup], title: String, inRotation: Bool, verb: String) -> some View {
        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
            Section {
                ForEach(group.lines) { line in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.name)
                            if let c = line.category, !c.isEmpty { Text(c).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button(verb) { Task { await apply([line.itemId], inRotation: inRotation) } }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                if group.lines.count > 1 {
                    Button("\(verb) all \(group.lines.count)") {
                        Task { await apply(group.lines.map(\.itemId), inRotation: inRotation) }
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    if index == 0 { Text(title).font(.headline).foregroundStyle(.primary).textCase(nil) }
                    HStack(spacing: 6) {
                        if let owner = group.owner {
                            TIK.PersonDot(name: owner, colorHex: people.first { $0.name == owner }?.colorHex, size: 18)
                        }
                        Text("\(group.location) · \(group.lines.count) item\(group.lines.count == 1 ? "" : "s")")
                    }
                }
            }
        }
    }

    private func apply(_ ids: [UUID], inRotation: Bool) async {
        do {
            try await env.inventory.applySwap(itemIds: ids, inRotation: inRotation)
            if !inRotation {
                moveIds = ids
                offerMove = true
            }
        } catch {
            errorText = "Couldn’t swap. \(error.localizedDescription)"
        }
    }

    private func swapAll() async {
        let outIds = getOut.flatMap { $0.lines.map(\.itemId) }
        let awayIds = putAway.flatMap { $0.lines.map(\.itemId) }
        do {
            if !outIds.isEmpty { try await env.inventory.applySwap(itemIds: outIds, inRotation: true) }
            if !awayIds.isEmpty {
                try await env.inventory.applySwap(itemIds: awayIds, inRotation: false)
                moveIds = awayIds
                offerMove = true
            }
        } catch {
            errorText = "Couldn’t swap. \(error.localizedDescription)"
        }
    }
}

#Preview {
    NavigationStack { SeasonalSwapView() }.environment(AppEnvironment.preview())
}

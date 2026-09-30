import SwiftUI
import HomeCore
import HomeCoreTesting

/// Global search (spec 09 FR-SES-01..08, LLD §12). Prefix AND matching with OR fallback lives in `SearchService`;
/// this view debounces typing (120 ms), groups hits by kind, shows each hit's location path and the "where is"
/// answer card when the top hit is an inventory item or storage spot.
///
/// Routing: pass `onOpen` to handle taps yourself (e.g. the plan selects the room). Without it, things,
/// inventory items and measurements open their edit forms in a sheet, storage spots and rooms open the room's
/// storage tree, and chores/projects are handed to the plan via `env.pendingDeepLink` and the search closes.
/// `onShowLocation` handles a tap on the answer card's path (switch floor, select room, flash the spot pin).
/// Self-contained: presents its own `NavigationStack`; show it in a sheet / full-screen cover.
struct SearchView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    private let initialQuery: String
    private let onOpen: ((SearchHit) -> Void)?
    private let onShowLocation: ((ItemLocation) -> Void)?

    @State private var query: String
    @State private var propertyId: UUID?
    @State private var hits: [SearchHit] = []
    @State private var searchedText = ""
    @State private var cardLocation: ItemLocation?
    @State private var route: Route?
    @State private var errorText: String?

    private enum Route: Identifiable {
        case thing(UUID), inventory(UUID), measurement(UUID), storage(UUID)
        var id: String {
            switch self {
            case .thing(let i): return "t:\(i)"; case .inventory(let i): return "i:\(i)"
            case .measurement(let i): return "m:\(i)"; case .storage(let i): return "s:\(i)"
            }
        }
    }

    init(query: String = "", onOpen: ((SearchHit) -> Void)? = nil, onShowLocation: ((ItemLocation) -> Void)? = nil) {
        initialQuery = query
        self.onOpen = onOpen
        self.onShowLocation = onShowLocation
        _query = State(initialValue: query)
    }

    private var sections: [HitSection] {
        TIK.groupedHits(hits).map { HitSection(type: $0.0, hits: $0.1) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let top = TIK.whereIsHit(hits) {
                    Section { whereIsCard(top) }
                }
                ForEach(sections) { section in
                    Section(section.type.displayName) {
                        ForEach(section.hits) { hit in
                            Button { open(hit) } label: { hitRow(hit) }
                        }
                    }
                }
            }
            .overlay {
                if TIK.isSearchable(searchedText) && hits.isEmpty {
                    ContentUnavailableView("No matches for ‘\(searchedText)’", systemImage: "magnifyingglass",
                                           description: Text("Check the spelling or try fewer words."))
                } else if !TIK.isSearchable(query) {
                    ContentUnavailableView("Search your home", systemImage: "magnifyingglass",
                                           description: Text("To-dos, projects, appliances, inventory, measurements, rooms and storage spots. Try “winter coat” or “16x25”."))
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search your home")
            .autocorrectionDisabled()
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $route) { r in destination(r) }
            .alert("Search failed", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
            .task { propertyId = try? await env.plan.currentProperty()?.id }
            .task(id: "\(propertyId?.uuidString ?? "-")|\(query)") {
                try? await Task.sleep(nanoseconds: 120_000_000)  // FR-SES-04 debounce
                guard !Task.isCancelled else { return }
                await runSearch(query)
            }
        }
        .feedbackPage("Search")
    }

    // MARK: Rows

    private func hitRow(_ hit: SearchHit) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: TIK.symbol(for: hit.entityType)).frame(width: 24).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.title).foregroundStyle(.primary)
                if let loc = hit.location, !loc.isEmpty {
                    Text(loc).font(.caption).foregroundStyle(.secondary)
                }
                if let snippet = hit.snippet, !snippet.isEmpty {
                    Text(snippet).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let people = hit.people, !people.isEmpty {
                Text(people).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "Winter coat → Attic › Shelf 2 › Bin Winter – Matt (Matt)".
    private func whereIsCard(_ hit: SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Best match").font(.caption).foregroundStyle(.secondary)
            Button { open(hit) } label: {
                HStack(spacing: 6) {
                    Text(hit.title).font(.headline).foregroundStyle(.primary)
                    if let owner = cardLocation?.owner ?? hit.people, !owner.isEmpty {
                        Text("· \(owner)").font(.headline).foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            Button { showLocation(hit) } label: {
                Label(cardPath(hit), systemImage: "arrow.turn.down.right")
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows where it is")
    }

    private func cardPath(_ hit: SearchHit) -> String {
        if let loc = cardLocation, loc.itemId == hit.entityId {
            return loc.displayPath + (loc.floor.map { " · \($0)" } ?? "")
        }
        return hit.location ?? ""
    }

    @ViewBuilder
    private func destination(_ r: Route) -> some View {
        switch r {
        case .thing(let id): ThingForm(thingID: id)
        case .inventory(let id): InventoryForm(itemID: id)
        case .measurement(let id): MeasurementForm(measurementID: id)
        case .storage(let spaceID):
            NavigationStack {
                StorageTreeView(spaceID: spaceID)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { route = nil } } }
            }
        }
    }

    // MARK: Actions

    private func runSearch(_ text: String) async {
        guard let pid = propertyId, TIK.isSearchable(text) else {
            hits = []; searchedText = ""; cardLocation = nil
            return
        }
        do {
            let result = try await env.search.search(text, property: pid)
            guard !Task.isCancelled else { return }
            hits = result
            searchedText = text
            if let top = TIK.whereIsHit(result), top.entityType == .inventoryItem {
                cardLocation = (try? await env.inventory.locations(of: [top.entityId]))?.first
            } else {
                cardLocation = nil
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func open(_ hit: SearchHit) {
        if let onOpen { onOpen(hit); return }
        switch hit.entityType {
        case .thing: route = .thing(hit.entityId)
        case .inventoryItem: route = .inventory(hit.entityId)
        case .measurement: route = .measurement(hit.entityId)
        case .space: route = .storage(hit.entityId)
        case .storageSpot:
            Task {
                if let spot = try? await env.inventory.spot(hit.entityId) { route = .storage(spot.spaceId) }
            }
        case .chore, .project:
            env.pendingDeepLink = hit.itemRef
            dismiss()
        }
    }

    private func showLocation(_ hit: SearchHit) {
        Task {
            var loc = cardLocation
            if loc == nil || loc?.itemId != hit.entityId {
                if hit.entityType == .storageSpot, let spot = try? await env.inventory.spot(hit.entityId) {
                    loc = ItemLocation(itemId: hit.entityId, name: hit.title, owner: hit.people, room: nil, floor: nil,
                                       spotPath: nil, levelId: nil, spaceId: spot.spaceId, spotId: spot.id)
                }
            }
            guard let loc else { return }
            if let onShowLocation { onShowLocation(loc); return }
            if let sid = loc.spaceId { route = .storage(sid) }
        }
    }
}

private struct HitSection: Identifiable {
    let type: SearchEntityType
    let hits: [SearchHit]
    var id: String { type.rawValue }
}

#Preview("Winter coat") {
    SearchView(query: "winter co").environment(AppEnvironment.preview())
}

#Preview("Filter size") {
    SearchView(query: "16x25").environment(AppEnvironment.preview())
}

import SwiftUI
import HomeCore
import HomeCoreTesting

/// Storage tree (spec 08 FR-INV-10..14, mockup 5.1).
///
/// - `StorageTreeView()` — every room with its item count; tap a room for its tree.
/// - `StorageTreeView(spaceID:)` — one room: nested spots with item counts (incl. descendants), add / rename /
///   move / delete spots, "Add item here", and the room's loose items.
/// Pushable (no own `NavigationStack`); wrap it in one when presenting as a sheet.
struct StorageTreeView: View {
    let spaceID: UUID?

    init(spaceID: UUID? = nil) { self.spaceID = spaceID }

    var body: some View {
        if let spaceID {
            RoomStorageTree(spaceID: spaceID)
        } else {
            StorageRoomsList()
        }
    }
}

// MARK: - Rooms list

private struct StorageRoomsList: View {
    @Environment(AppEnvironment.self) private var env
    @State private var places = TIK.PlaceIndex()
    @State private var propertyId: UUID?
    @State private var counts: [UUID: Int] = [:]

    var body: some View {
        List {
            ForEach(places.levels) { level in
                let rooms = places.spaces(on: level.id)
                if !rooms.isEmpty {
                    Section(level.name) {
                        ForEach(rooms) { room in
                            NavigationLink {
                                StorageTreeView(spaceID: room.id)
                            } label: {
                                LabeledContent(room.name, value: counts[room.id].map { "\($0) item\($0 == 1 ? "" : "s")" } ?? "")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Storage")
        .overlay {
            if places.spaces.isEmpty {
                ContentUnavailableView("No rooms yet", systemImage: "archivebox",
                                       description: Text("Add rooms to your plan, then add shelves, closets or bins to them."))
            }
        }
        .task {
            let (p, idx) = await TIK.loadPlaces(env)
            places = idx
            propertyId = p?.id
        }
        .task(id: propertyId) {
            guard let pid = propertyId else { return }
            for await items in env.inventory.observeItems(InventoryQuery(propertyId: pid)) {
                var c: [UUID: Int] = [:]
                for i in items { if let s = i.scope.spaceId { c[s, default: 0] += 1 } }
                counts = c
            }
        }
    }
}

// MARK: - One room

private struct RoomStorageTree: View {
    @Environment(AppEnvironment.self) private var env
    let spaceID: UUID

    private enum NameEdit: Identifiable {
        case add(parent: SpotNode?)
        case rename(StorageSpot)
        var id: String {
            switch self {
            case .add(let p): return "add:\(p?.id.uuidString ?? "root")"
            case .rename(let s): return "rename:\(s.id)"
            }
        }
    }

    private enum Sheet: Identifiable {
        case newItem(spot: UUID?)
        case editItem(UUID)
        case moveSpot(SpotNode)
        var id: String {
            switch self {
            case .newItem(let s): return "new:\(s?.uuidString ?? "room")"
            case .editItem(let i): return "edit:\(i)"
            case .moveSpot(let n): return "move:\(n.id)"
            }
        }
    }

    @State private var space: Space?
    @State private var propertyId: UUID?
    @State private var nodes: [SpotNode] = []
    @State private var looseItems: [InventoryItem] = []
    @State private var nameEdit: NameEdit?
    /// Kept separately from `nameEdit` (which the alert clears on dismiss) so Save always knows what to do.
    @State private var activeEdit: NameEdit?
    @State private var nameText = ""
    @State private var sheet: Sheet?
    @State private var pendingDelete: SpotNode?
    @State private var errorText: String?

    var body: some View {
        List {
            Section {
                if nodes.isEmpty {
                    Text("Add a shelf, closet or bin to start tracking where things are.")
                        .foregroundStyle(.secondary)
                }
                ForEach(TIK.flatten(nodes)) { node in
                    NavigationLink {
                        StorageSpotItemsView(spotID: node.id, title: node.spot.name, path: "\(space?.name ?? "") › \(node.path)")
                    } label: {
                        spotRow(node)
                    }
                    .contextMenu { spotActions(node) }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) { pendingDelete = node }
                        Button("Rename") { beginRename(node.spot) }.tint(.gray)
                    }
                }
            } header: {
                Text("Storage spots")
            }
            Section {
                ForEach(looseItems) { item in
                    Button { sheet = .editItem(item.id) } label: { TIK.InventoryRow(item: item) }
                }
                Button { sheet = .newItem(spot: nil) } label: { Label("Add item", systemImage: "plus") }
            } header: {
                Text("Not in a spot")
            }
        }
        .navigationTitle(space?.name ?? "Storage")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { beginAdd(parent: nil) } label: { Label("Add spot", systemImage: "archivebox") }
                    Button { sheet = .newItem(spot: nil) } label: { Label("Add item", systemImage: "shippingbox") }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add")
            }
        }
        .alert(nameEdit.map { alertTitle($0) } ?? "", isPresented: Binding(get: { nameEdit != nil }, set: { if !$0 { nameEdit = nil } })) {
            TextField("Name", text: $nameText)
            Button("Cancel", role: .cancel) { nameEdit = nil }
            Button("Save") { if let e = activeEdit { Task { await commitName(e) } } }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { node in
            Button(node.subtreeItemCount > 0 ? "Move items and delete" : "Delete", role: .destructive) {
                Task { await deleteSpot(node) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { node in
            Text(deleteMessage(node))
        }
        .alert("Can’t do that", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .newItem(let spot):
                if let spot { InventoryForm(spotID: spot) } else { InventoryForm(spaceID: spaceID) }
            case .editItem(let id):
                InventoryForm(itemID: id)
            case .moveSpot(let node):
                MoveSpotSheet(node: node, nodes: nodes, roomName: space?.name ?? "room")
            }
        }
        .task {
            space = try? await env.plan.space(spaceID)
            propertyId = space?.propertyId
        }
        .task {
            for await tree in env.inventory.observeSpotTree(space: spaceID) { nodes = tree }
        }
        .task(id: space?.id) {
            guard let space else { return }
            for await items in env.inventory.observeItems(InventoryQuery(propertyId: space.propertyId, scope: space.scope)) {
                looseItems = items.filter { $0.storageSpotId == nil }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        }
    }

    private func spotRow(_ node: SpotNode) -> some View {
        HStack(spacing: 10) {
            Image(systemName: node.depth == 0 ? "archivebox" : "shippingbox")
                .foregroundStyle(.tint)
            Text(node.spot.name)
            Spacer()
            Text("\(node.subtreeItemCount)").foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.leading, CGFloat(min(node.depth, 8)) * 18)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(node.path), \(node.subtreeItemCount) items")
    }

    @ViewBuilder
    private func spotActions(_ node: SpotNode) -> some View {
        Button { sheet = .newItem(spot: node.id) } label: { Label("Add item here", systemImage: "plus") }
        Button { beginAdd(parent: node) } label: { Label("Add spot inside", systemImage: "archivebox") }
        Button { beginRename(node.spot) } label: { Label("Rename", systemImage: "pencil") }
        Button { sheet = .moveSpot(node) } label: { Label("Move to…", systemImage: "arrow.turn.down.right") }
        Button(role: .destructive) { pendingDelete = node } label: { Label("Delete", systemImage: "trash") }
    }

    private func alertTitle(_ e: NameEdit) -> String {
        switch e {
        case .add(let parent): return parent.map { "New spot in \($0.spot.name)" } ?? "New spot"
        case .rename: return "Rename spot"
        }
    }

    private var deleteTitle: String { pendingDelete.map { "Delete “\($0.spot.name)”?" } ?? "" }

    private func deleteMessage(_ node: SpotNode) -> String {
        let target = parentName(of: node) ?? space?.name ?? "the room"
        let sub = node.children.isEmpty ? "" : " Spots inside it are deleted too."
        guard node.subtreeItemCount > 0 else { return "It moves to Recently Deleted for 30 days.\(sub)" }
        let n = node.subtreeItemCount
        return "Move \(n) item\(n == 1 ? "" : "s") to \(target)?\(sub)"
    }

    private func parentName(of node: SpotNode) -> String? {
        guard let pid = node.spot.parentSpotId else { return nil }
        return TIK.flatten(nodes).first { $0.id == pid }?.spot.name
    }

    private func beginAdd(parent: SpotNode?) { nameText = ""; activeEdit = .add(parent: parent); nameEdit = activeEdit }
    private func beginRename(_ spot: StorageSpot) { nameText = spot.name; activeEdit = .rename(spot); nameEdit = activeEdit }

    private func commitName(_ edit: NameEdit) async {
        let name = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        nameEdit = nil
        activeEdit = nil
        guard !name.isEmpty else { return }
        do {
            switch edit {
            case .add(let parent):
                guard let pid = propertyId else { return }
                let siblings = parent?.children.count ?? nodes.count
                let spot = StorageSpot(propertyId: pid, spaceId: spaceID, parentSpotId: parent?.id, name: name,
                                       ownerId: parent?.spot.ownerId, sortOrder: siblings,
                                       createdAt: env.clock.now, updatedAt: env.clock.now)
                try await env.inventory.saveSpot(spot)
            case .rename(var spot):
                spot.name = name
                try await env.inventory.saveSpot(spot)
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func deleteSpot(_ node: SpotNode) async {
        pendingDelete = nil
        do {
            try await env.inventory.deleteSpot(node.id, moveItemsTo: node.spot.parentSpotId)
        } catch {
            errorText = "Couldn’t delete the spot. \(error.localizedDescription)"
        }
    }
}

// MARK: - Move a spot (FR-INV-12/13, AC-INV-7)

private struct MoveSpotSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let node: SpotNode
    let nodes: [SpotNode]
    let roomName: String
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { Task { await move(to: nil) } } label: {
                        row("Top level of \(roomName)", depth: 0, current: node.spot.parentSpotId == nil)
                    }
                    ForEach(TIK.validParents(for: node.id, in: nodes)) { candidate in
                        Button { Task { await move(to: candidate.id) } } label: {
                            row(candidate.spot.name, depth: candidate.depth + 1, current: node.spot.parentSpotId == candidate.id)
                        }
                    }
                } footer: {
                    Text("Everything inside “\(node.spot.name)” moves with it. A spot can’t go inside itself.")
                }
                if let errorText { Section { Text(errorText).foregroundStyle(.red) } }
            }
            .navigationTitle("Move “\(node.spot.name)”")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func row(_ title: String, depth: Int, current: Bool) -> some View {
        HStack {
            Text(title).foregroundStyle(.primary).padding(.leading, CGFloat(min(depth, 8)) * 16)
            Spacer()
            if current { Image(systemName: "checkmark").foregroundStyle(.tint) }
        }
    }

    private func move(to parent: UUID?) async {
        guard parent != node.spot.parentSpotId else { dismiss(); return }
        do {
            try await env.inventory.reparentSpot(node.id, to: parent)
            dismiss()
        } catch RepositoryError.cycle {
            errorText = "A spot can’t go inside itself."
        } catch {
            errorText = "Couldn’t move the spot. \(error.localizedDescription)"
        }
    }
}

// MARK: - Items in a spot (multi-select → Move to…, FR-INV-23)

struct StorageSpotItemsView: View {
    @Environment(AppEnvironment.self) private var env
    let spotID: UUID
    let title: String
    var path: String? = nil

    @State private var items: [InventoryItem] = []
    @State private var locations: [UUID: ItemLocation] = [:]
    @State private var selection = Set<UUID>()
    @State private var editMode: EditMode = .inactive
    @State private var showMove = false
    @State private var showAdd = false
    @State private var editing: InventoryItem?

    var body: some View {
        List(selection: $selection) {
            if let path { Section { Text(path).font(.subheadline).foregroundStyle(.secondary) } }
            Section {
                ForEach(items) { item in
                    Button { if editMode == .inactive { editing = item } } label: {
                        TIK.InventoryRow(item: item, subtitle: nestedPath(item))
                    }
                    .tag(item.id)
                }
            } footer: {
                if items.isEmpty { Text("Nothing here yet.") }
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAdd = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add item here")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(editMode == .active ? "Done" : "Select") {
                    editMode = editMode == .active ? .inactive : .active
                    if editMode == .inactive { selection.removeAll() }
                }
                .disabled(items.isEmpty)
            }
            ToolbarItem(placement: .bottomBar) {
                if editMode == .active {
                    Button("Move \(selection.count) to…") { showMove = true }.disabled(selection.isEmpty)
                }
            }
        }
        .sheet(isPresented: $showMove) {
            TIK.MoveItemsSheet(itemIds: Array(selection)) {
                selection.removeAll()
                editMode = .inactive
            }
        }
        .sheet(isPresented: $showAdd) { InventoryForm(spotID: spotID) }
        .sheet(item: $editing) { item in InventoryForm(itemID: item.id) }
        .task {
            guard let spot = try? await env.inventory.spot(spotID) else { return }
            for await list in env.inventory.observeItems(InventoryQuery(propertyId: spot.propertyId, spotId: spotID)) {
                items = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                let locs = (try? await env.inventory.locations(of: list.map(\.id))) ?? []
                locations = Dictionary(locs.map { ($0.itemId, $0) }, uniquingKeysWith: { a, _ in a })
            }
        }
    }

    /// For items in a sub-spot, show which one.
    private func nestedPath(_ item: InventoryItem) -> String? {
        guard item.storageSpotId != spotID else { return nil }
        return locations[item.id]?.spotPath
    }
}

extension TIK {
    /// Compact inventory row: name, quantity, owner/season, low/expiry badges.
    struct InventoryRow: View {
        @Environment(AppEnvironment.self) private var env
        let item: InventoryItem
        var subtitle: String? = nil

        var body: some View {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).foregroundStyle(.primary)
                    let detail = details
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if item.isLow { Text("Low").font(.caption.weight(.semibold)).foregroundStyle(.orange) }
                switch TIK.expiryTone(item.expiresOn, today: env.clock.today) {
                case .expired: Text("Expired").font(.caption.weight(.semibold)).foregroundStyle(.red)
                case .soon: Text("Expiring").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                case .none: EmptyView()
                }
                Text(TIK.quantityLabel(item.quantity, unit: item.unit)).foregroundStyle(.secondary).monospacedDigit()
            }
        }

        private var details: String {
            var parts: [String] = []
            if let subtitle { parts.append(subtitle) }
            if item.kind == .clothing {
                if let s = item.season, s != .unknown { parts.append(TIK.seasonTitle(s)) }
                if let r = item.inRotation { parts.append(r ? "In rotation" : "Stored") }
            } else if let c = item.category, !c.isEmpty {
                parts.append(c)
            }
            return parts.joined(separator: " · ")
        }
    }
}

#Preview("All rooms") {
    NavigationStack { StorageTreeView() }.environment(AppEnvironment.preview())
}

#Preview("Storage room tree") {
    NavigationStack { StorageTreeView(spaceID: SampleHome.storageId) }.environment(AppEnvironment.preview())
}

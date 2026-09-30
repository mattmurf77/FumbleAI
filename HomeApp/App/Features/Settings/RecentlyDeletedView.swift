import SwiftUI
import HomeCore
import HomeCoreTesting

/// Settings › Recently Deleted (spec 09 FR-SES-60..65): newest first with kind, original location and days
/// left; Restore, Delete now (confirmed) and Delete all now (confirmed). Pushable.
struct RecentlyDeletedView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var propertyId: UUID?
    @State private var entries: [DeletedEntry] = []
    @State private var loaded = false
    @State private var selected: DeletedEntry?
    @State private var pendingPurge: DeletedEntry?
    @State private var confirmPurgeAll = false
    @State private var errorText: String?

    var body: some View {
        List {
            if !entries.isEmpty {
                Section {
                    ForEach(entries) { entry in
                        Button { selected = entry } label: { row(entry) }
                            .swipeActions(edge: .trailing) {
                                Button("Delete now", role: .destructive) { pendingPurge = entry }
                                Button("Restore") { Task { await restore(entry) } }.tint(.blue)
                            }
                    }
                } footer: {
                    Text("Items are removed for good after \(DeletedEntry.retentionDays) days, on every device.")
                }
            }
        }
        .navigationTitle("Recently Deleted")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Delete all", role: .destructive) { confirmPurgeAll = true }
                    .disabled(entries.isEmpty)
            }
        }
        .overlay {
            if loaded && entries.isEmpty {
                ContentUnavailableView("Nothing deleted in the last 30 days", systemImage: "trash")
            }
        }
        .confirmationDialog(selected?.title ?? "", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }),
                            titleVisibility: .visible, presenting: selected) { entry in
            Button("Restore") { Task { await restore(entry) } }
            Button("Delete now", role: .destructive) { pendingPurge = entry }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(pendingPurge?.title ?? "")” now?",
                            isPresented: Binding(get: { pendingPurge != nil }, set: { if !$0 { pendingPurge = nil } }),
                            titleVisibility: .visible, presenting: pendingPurge) { entry in
            Button("Delete now", role: .destructive) { Task { await purge([entry]) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This can’t be undone.")
        }
        .confirmationDialog("Delete all \(entries.count) items now?", isPresented: $confirmPurgeAll, titleVisibility: .visible) {
            Button("Delete all now", role: .destructive) { Task { await purge(entries) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can’t be undone.")
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .task { propertyId = try? await env.plan.currentProperty()?.id }
        .task(id: propertyId) {
            guard let pid = propertyId else { return }
            for await list in env.recentlyDeleted.observeDeleted(property: pid) {
                entries = list.sorted { $0.deletedAt > $1.deletedAt }
                loaded = true
            }
        }
    }

    private func row(_ e: DeletedEntry) -> some View {
        let days = e.daysLeft(now: env.clock.now)
        return VStack(alignment: .leading, spacing: 2) {
            Text(e.title).foregroundStyle(.primary)
            Text([e.kindLabel, e.originalLocation].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            Text(days == 0 ? "Removed today" : "\(days) day\(days == 1 ? "" : "s") left")
                .font(.caption2).foregroundStyle(days <= 3 ? Color.orange : Color.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func restore(_ e: DeletedEntry) async {
        selected = nil
        do { try await env.recentlyDeleted.restore(e.ref) } catch { errorText = "Couldn’t restore “\(e.title)”. \(error.localizedDescription)" }
    }

    private func purge(_ list: [DeletedEntry]) async {
        pendingPurge = nil
        for e in list {
            do { try await env.recentlyDeleted.purge(e.ref) } catch { errorText = "Couldn’t delete “\(e.title)”. \(error.localizedDescription)" }
        }
    }
}

#Preview {
    NavigationStack { RecentlyDeletedView() }.environment(AppEnvironment.preview())
}

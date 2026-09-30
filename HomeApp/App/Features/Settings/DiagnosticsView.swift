import SwiftUI
import HomeCore
import HomeCoreTesting

/// Settings › Diagnostics (spec 09 FR-SES-41..43): iCloud account/sync state, pending notifications (x/64),
/// permissions, counts-only data summary, "Export diagnostics" (counts only, no titles/names/notes/photos),
/// "Rebuild search index" and "Re-run reminder scheduling". Pushable.
struct DiagnosticsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var sync = SyncDiagnostics()
    @State private var reminders = ReminderStatus()
    @State private var notificationAuth: PermissionStatus = .unknown
    @State private var calendarAuth: PermissionStatus = .unknown
    @State private var counts: DiagnosticsCounts?
    @State private var exportURL: URL?
    @State private var busy: String?
    @State private var message: String?

    var body: some View {
        List {
            Section("iCloud") {
                LabeledContent("Account", value: sync.accountStatus)
                LabeledContent("Status", value: env.syncStatus.displayText)
                LabeledContent("Last fetch", value: dateText(sync.lastFetchAt))
                LabeledContent("Last send", value: dateText(sync.lastSendAt))
                LabeledContent("Changes waiting to send", value: "\(sync.outboxCount)")
                LabeledContent("Parked records", value: "\(sync.parkedOrphans)")
                if let e = sync.lastError, !e.isEmpty {
                    LabeledContent("Last error", value: e)
                }
            }
            Section("Reminders") {
                LabeledContent("Pending notifications", value: "\(reminders.pendingCount)/\(reminders.limit)")
                LabeledContent("Notifications", value: TIK.permissionText(notificationAuth))
                LabeledContent("Last scheduled", value: dateText(reminders.lastReplanAt))
                Button("Re-run reminder scheduling") {
                    Task { await run("Rescheduled reminders.") { await env.reminders.replan(reason: .manual) } }
                }
                .disabled(busy != nil)
            }
            Section("Calendar") {
                LabeledContent("Calendar access", value: TIK.permissionText(calendarAuth))
                LabeledContent("This device", value: env.device.nickname)
            }
            if let counts {
                Section("Data (counts only)") {
                    LabeledContent("Floors", value: "\(counts.levels)")
                    ForEach(counts.spacesBySource.keys.sorted(), id: \.self) { k in
                        LabeledContent("Rooms · \(k)", value: "\(counts.spacesBySource[k] ?? 0)")
                    }
                    ForEach(counts.itemsByKind.keys.sorted(), id: \.self) { k in
                        LabeledContent(k.replacingOccurrences(of: "_", with: " ").capitalized, value: "\(counts.itemsByKind[k] ?? 0)")
                    }
                    LabeledContent("To-dos with reminder", value: "\(counts.choresWithReminder)")
                    LabeledContent("To-dos with calendar", value: "\(counts.choresWithCalendar)")
                    LabeledContent("Done projects with actual cost", value: "\(counts.doneProjectsWithActual)")
                    LabeledContent("Done projects with receipt", value: "\(counts.doneProjectsWithReceipt)")
                }
            }
            Section {
                Button("Rebuild search index") {
                    Task { await run("Search index rebuilt.") { try? await env.search.rebuildIndex() } }
                }
                .disabled(busy != nil)
                if let exportURL {
                    ShareLink(item: exportURL) { Label("Share \(exportURL.lastPathComponent)", systemImage: "square.and.arrow.up") }
                } else {
                    Button("Export diagnostics") { Task { await exportDiagnostics() } }
                        .disabled(busy != nil)
                }
            } header: {
                Text("Tools")
            } footer: {
                Text("The diagnostics file has a 24-hour log, performance reports and counts only — no titles, names, notes, addresses or photos. Nothing is sent unless you share it.")
            }
            if let busy {
                Section { HStack { ProgressView(); Text(busy) } }
            } else if let message {
                Section { Text(message).foregroundStyle(.secondary) }
            }
        }
        .feedbackPage("Settings · Diagnostics")
        .navigationTitle("Diagnostics")
        .refreshable { await load() }
        .task { await load() }
    }

    private func dateText(_ d: Date?) -> String {
        d.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never"
    }

    private func load() async {
        sync = await env.sync.diagnostics()
        reminders = await env.reminders.status()
        notificationAuth = await env.notificationAuth.authorizationStatus()
        calendarAuth = await env.calendar.authorizationStatus()
        if let pid = try? await env.plan.currentProperty()?.id {
            counts = try? await env.diagnostics.counts(property: pid)
        }
    }

    private func run(_ done: String, _ work: () async -> Void) async {
        busy = "Working…"
        message = nil
        await work()
        busy = nil
        message = done
        await load()
    }

    private func exportDiagnostics() async {
        busy = "Preparing diagnostics…"
        message = nil
        defer { busy = nil }
        do {
            guard let pid = try await env.plan.currentProperty()?.id else { return }
            exportURL = try await env.diagnostics.exportDiagnostics(property: pid)
        } catch {
            message = "Couldn’t create the diagnostics file. \(error.localizedDescription)"
        }
    }
}

#Preview {
    NavigationStack { DiagnosticsView() }.environment(AppEnvironment.preview())
}

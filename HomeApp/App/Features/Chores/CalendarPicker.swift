import SwiftUI
import HomeCore
import HomeCoreTesting

/// Calendar picker (FR-CHR-52/53, mockup 4.1): "Create 'Home' calendar" first (suggested, iCloud or on-device), then
/// writable calendars grouped by account ("iCloud", "Gmail – you@…", "Exchange"). Google calendars appear when the
/// Google account is added in iPhone Settings › Calendar › Accounts.
struct CalendarPicker: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String?

    @State private var calendars: [CalendarInfo] = []
    @State private var loading = true
    @State private var creating = false
    @State private var error: String?

    private static let homeTitle = "Home"

    private struct SourceGroup: Identifiable {
        var source: String
        var calendars: [CalendarInfo]
        var id: String { source }
        var isGoogle: Bool { source.lowercased().contains("gmail") || source.lowercased().contains("google") }
    }

    private var existingHome: CalendarInfo? {
        let homes = calendars.filter { $0.title.caseInsensitiveCompare(Self.homeTitle) == .orderedSame }
        return homes.first { $0.sourceTitle.lowercased().contains("icloud") } ?? homes.first
    }

    private var groups: [SourceGroup] {
        let by = Dictionary(grouping: calendars.filter { $0.id != existingHome?.id }, by: \.sourceTitle)
        func rank(_ s: String) -> Int { s.lowercased().contains("icloud") ? 0 : (s == "On My iPhone" ? 1 : 2) }
        return by.keys.sorted { (rank($0), $0) < (rank($1), $1) }.map { key in
            SourceGroup(source: key, calendars: (by[key] ?? []).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending })
        }
    }

    var body: some View {
        List {
            Section {
                if let home = existingHome {
                    row(home, suggested: true)
                } else {
                    Button {
                        Task { await createHome() }
                    } label: {
                        HStack {
                            Label("Create “Home” calendar", systemImage: "calendar.badge.plus")
                            Spacer()
                            if creating { ProgressView() } else { SuggestedTag() }
                        }
                    }
                    .disabled(creating)
                }
            } footer: {
                Text("A separate “Home” calendar in iCloud keeps chores apart from your other events.")
            }

            ForEach(groups) { group in
                Section {
                    ForEach(group.calendars) { row($0, suggested: false) }
                } header: {
                    Text(group.source)
                } footer: {
                    if group.isGoogle {
                        Text("iOS can’t create a new calendar inside a Google account, so pick one of these.")
                    }
                }
            }

            Section {
                EmptyView()
            } footer: {
                Text("Google calendars appear here when the Google account is added in iPhone Settings › Calendar › Accounts.")
            }
        }
        .overlay {
            if loading { ProgressView() }
            else if calendars.isEmpty && existingHome == nil && groups.isEmpty {
                ContentUnavailableView("No calendars", systemImage: "calendar",
                                       description: Text("Allow calendar access for Home in Settings, or create the “Home” calendar."))
            }
        }
        .navigationTitle("Calendar")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn’t create the calendar", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
        .task { await load() }
    }

    private func row(_ c: CalendarInfo, suggested: Bool) -> some View {
        Button {
            selection = c.id
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Circle().fill(Color(scheduleHex: c.colorHex) ?? .accentColor).frame(width: 11, height: 11)
                Text(c.title).foregroundStyle(.primary)
                if suggested { SuggestedTag() }
                Spacer()
                if selection == c.id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
        }
        .accessibilityAddTraits(selection == c.id ? .isSelected : [])
    }

    private func load() async {
        calendars = await env.calendar.writableCalendars()
        loading = false
    }

    private func createHome() async {
        creating = true
        defer { creating = false }
        do {
            let c = try await env.calendar.createHomeCalendar()
            calendars = await env.calendar.writableCalendars()
            if !calendars.contains(where: { $0.id == c.id }) { calendars.insert(c, at: 0) }
            selection = c.id
            dismiss()
        } catch {
            self.error = "Pick an existing calendar instead. (\(error.localizedDescription))"
        }
    }
}

private struct SuggestedTag: View {
    var body: some View {
        Text("Suggested")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
            .foregroundStyle(Color.accentColor)
    }
}

extension Color {
    /// "#RRGGBB" → Color.
    init?(scheduleHex hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// The "Calendar" section of the chore form (FR-CHR-50…59): toggle, calendar row, owner-device note.
/// Access (full) is requested the first time the toggle is switched on; if denied the toggle reverts with an explanation.
struct ChoreCalendarSection: View {
    @Environment(AppEnvironment.self) private var env
    /// nil while creating a chore.
    let choreId: UUID?
    let rule: RepeatRule?
    @Binding var isOn: Bool
    @Binding var calendarId: String?

    @State private var ownership: CalendarOwnership = .notEnabled
    @State private var calendarTitle: String?
    @State private var deniedNote = false
    @State private var adopting = false
    @State private var adoptError: String?

    var body: some View {
        Section {
            if case .ownedByOtherDevice(let nickname) = ownership {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Calendar events are managed on ‘\(nickname)’", systemImage: "iphone")
                    Button(adopting ? "Moving…" : "Manage from this iPhone") { Task { await adopt() } }
                        .disabled(adopting)
                    if let adoptError { Text(adoptError).font(.footnote).foregroundStyle(.red) }
                }
            } else {
                Toggle(isOn: Binding(get: { isOn }, set: { on in
                    if on { Task { await switchOn() } } else { isOn = false }
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Add to calendar", systemImage: "calendar")
                        if isOn { Text(subtitle).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                if isOn {
                    NavigationLink {
                        CalendarPicker(selection: $calendarId)
                    } label: {
                        LabeledContent("Calendar", value: calendarTitle ?? "Choose…")
                    }
                }
                if deniedNote {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Home needs full calendar access to add, update and remove chore events.")
                        ScheduleSettingsLink()
                    }
                    .font(.footnote)
                }
            }
        } header: {
            Text("Calendar")
        } footer: {
            Text("Past events stay in your calendar. Editing a chore changes future events only.")
        }
        .task(id: calendarId) { await refresh() }
    }

    private var subtitle: String {
        guard let rule, rule.anchor == .schedule else { return "One event on the due date" }
        return "Repeats · " + rule.humanText.lowercased()
    }

    @MainActor
    private func refresh() async {
        if let choreId { ownership = await env.calendar.ownership(chore: choreId) }
        if calendarId == nil, isOn {
            calendarId = await env.settings.load().defaultCalendarId
        }
        if let calendarId {
            calendarTitle = await env.calendar.writableCalendars().first { $0.id == calendarId }?.title
        } else if case .ownedByThisDevice(let title) = ownership {
            calendarTitle = title
        }
    }

    @MainActor
    private func switchOn() async {
        deniedNote = false
        var status = await env.calendar.authorizationStatus()
        if status == .notDetermined {
            _ = try? await env.calendar.requestAccess()
            status = await env.calendar.authorizationStatus()
        }
        guard status == .authorized else {
            isOn = false
            deniedNote = true
            return
        }
        isOn = true
        if calendarId == nil { calendarId = await env.settings.load().defaultCalendarId }
        await refresh()
    }

    @MainActor
    private func adopt() async {
        guard let choreId else { return }
        adopting = true
        defer { adopting = false }
        do {
            var status = await env.calendar.authorizationStatus()
            if status == .notDetermined { _ = try await env.calendar.requestAccess(); status = await env.calendar.authorizationStatus() }
            guard status == .authorized else { deniedNote = true; return }
            try await env.calendar.adoptOwnership(chore: choreId)
            ownership = await env.calendar.ownership(chore: choreId)
        } catch {
            adoptError = "Couldn’t move the calendar events. Try again."
        }
    }
}

private struct CalendarPickerPreview: View {
    @State var selection: String? = "cal-home"
    var body: some View { NavigationStack { CalendarPicker(selection: $selection) } }
}

#Preview("Picker") {
    CalendarPickerPreview().environment(AppEnvironment.preview())
}

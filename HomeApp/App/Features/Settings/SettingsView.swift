import SwiftUI
import HomeCore
import HomeCoreTesting

/// Settings (spec 09 FR-SES-40, spec 10 FR-SYN-16/22/30, mockup 6.3). Synced home settings (name, default floor,
/// units) are written to `Property`; device settings (reminder defaults, calendar, nickname, list view) go
/// through `SettingsRepository`. Self-contained: presents its own `NavigationStack` with Done; show it in a sheet.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var property: Property?
    @State private var levels: [Level] = []
    @State private var people: [Person] = []
    @State private var settings = AppSettings()
    @State private var homeName = ""
    @State private var nickname = ""
    @State private var calendarStatus: PermissionStatus = .unknown
    @State private var calendars: [CalendarInfo] = []
    @State private var errorText: String?
    @AppStorage(FeedbackSettings.showButtonKey) private var showFeedbackButton = true

    private static let offsets: [(Int, String)] = [
        (0, "At time"), (15, "15 minutes before"), (30, "30 minutes before"), (60, "1 hour before"),
        (120, "2 hours before"), (1440, "1 day before"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                homeSection
                housematesSection
                remindersSection
                calendarSection
                Section {
                    Toggle("Show plan as a list", isOn: setting(\.showPlanAsList))
                } header: {
                    Text("Accessibility")
                } footer: {
                    Text("Also on automatically with VoiceOver.")
                }
                iCloudSection
                Section("Data") {
                    NavigationLink { ExportView() } label: { Label("Export data (CSV)", systemImage: "square.and.arrow.up") }
                    NavigationLink { RecentlyDeletedView() } label: { Label("Recently Deleted", systemImage: "trash") }
                }
                Section {
                    Toggle("Show feedback button", isOn: $showFeedbackButton)
                    #if canImport(UIKit)
                    Button { FeedbackPresenter.shared.present() } label: { Label("Send feedback", systemImage: "exclamationmark.bubble") }
                    #endif
                } header: {
                    Text("Feedback")
                } footer: {
                    Text("Report a bug, suggest polish or share an idea from any screen. Shake your iPhone to send feedback even when the button is hidden.")
                }
                aboutSection
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Something went wrong", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
            .task {
                settings = await env.settings.load()
                nickname = settings.deviceNickname
                await refreshCalendars()
            }
            .task {
                for await p in env.plan.observeCurrentProperty() {
                    property = p
                    if let p, homeName.isEmpty { homeName = p.name }
                }
            }
            .task(id: property?.id) {
                guard let pid = property?.id else { return }
                for await list in env.plan.observeLevels(property: pid) { levels = list.filter { $0.deletedAt == nil }.sortedForPills }
            }
            .task(id: property?.id) {
                guard let pid = property?.id else { return }
                for await list in env.people.observePeople(property: pid) { people = list.sorted { $0.sortOrder < $1.sortOrder } }
            }
        }
        .feedbackPage("Settings")
    }

    // MARK: Home

    private var homeSection: some View {
        Section {
            TextField("Home name", text: $homeName)
                .submitLabel(.done)
                .onSubmit { saveHomeName() }
            if let address = property?.address?.singleLine, !address.isEmpty {
                LabeledContent("Address", value: address)
            }
            Picker("Default floor", selection: defaultFloorBinding) {
                ForEach(levels) { level in Text(level.name).tag(UUID?.some(level.id)) }
            }
            Picker("Units", selection: unitsBinding) {
                Text("Feet + inches").tag(UnitSystem.imperial)
                Text("Metric").tag(UnitSystem.metric)
            }
            if let currency = property?.currencyCode {
                LabeledContent("Currency", value: currency)
            }
        } header: {
            Text("Home")
        } footer: {
            Text("The plan opens on the default floor on every device. Change floors with the pill tabs.")
        }
    }

    private var defaultFloorBinding: Binding<UUID?> {
        Binding(
            get: { levels.defaultLevel(preferred: property?.defaultLevelId)?.id },
            set: { newValue in
                guard let id = newValue, let pid = property?.id else { return }
                Task {
                    do { try await env.plan.setDefaultLevel(id, property: pid) } catch { errorText = error.localizedDescription }
                }
            })
    }

    private var unitsBinding: Binding<UnitSystem> {
        Binding(
            get: { property?.unitSystem == .metric ? .metric : .imperial },
            set: { newValue in
                guard var p = property, p.unitSystem != newValue else { return }
                p.unitSystem = newValue
                p.updatedAt = env.clock.now
                Task { await saveProperty(p) }
            })
    }

    private func saveHomeName() {
        let name = homeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var p = property, !name.isEmpty, name != p.name else { return }
        p.name = name
        p.updatedAt = env.clock.now
        Task { await saveProperty(p) }
    }

    private func saveProperty(_ p: Property) async {
        do { try await env.plan.saveProperty(p) } catch { errorText = error.localizedDescription }
    }

    // MARK: Housemates

    private var housematesSection: some View {
        Section {
            ForEach(people) { p in
                HStack(spacing: 12) {
                    TIK.PersonDot(person: p)
                    Text(p.name)
                }
            }
            NavigationLink { PeopleEditor() } label: {
                Text(people.isEmpty ? "Add housemate" : "Edit housemates").foregroundStyle(.tint)
            }
        } header: {
            Text("Housemates")
        } footer: {
            Text("Housemates are name labels for now. Shared access comes in v1.2.")
        }
    }

    // MARK: Reminders

    private var remindersSection: some View {
        Section {
            DatePicker("Default time", selection: defaultTimeBinding, displayedComponents: .hourAndMinute)
                .environment(\.timeZone, env.clock.calendar.timeZone)
            Picker("Remind me", selection: setting(\.defaultRemindOffsetMin)) {
                ForEach(offsetChoices, id: \.0) { value, label in Text(label).tag(value) }
            }
            Toggle("App badge", isOn: setting(\.badgeEnabled))
            Toggle("Pantry expiry digest", isOn: setting(\.pantryDigestEnabled))
            Toggle("Offer to use a spare when a linked to-do is done", isOn: setting(\.spareStockPromptEnabled))
        } header: {
            Text("Reminders")
        } footer: {
            Text("The default time is used for to-dos without a time. The pantry digest is one 9 am notice when items expire within 3 days.")
        }
    }

    private var offsetChoices: [(Int, String)] {
        let current = settings.defaultRemindOffsetMin
        if Self.offsets.contains(where: { $0.0 == current }) { return Self.offsets }
        return Self.offsets + [(current, "\(current) minutes before")]
    }

    private var defaultTimeBinding: Binding<Date> {
        let cal = env.clock.calendar
        let today = env.clock.today
        return Binding(
            get: { today.date(atMinutes: settings.defaultAllDayMinutes, calendar: cal) ?? env.clock.now },
            set: { date in
                let c = cal.dateComponents([.hour, .minute], from: date)
                let minutes = (c.hour ?? 9) * 60 + (c.minute ?? 0)
                updateSettings { $0.defaultAllDayMinutes = minutes }
            })
    }

    // MARK: Calendar

    private var calendarSection: some View {
        Section {
            switch calendarStatus {
            case .authorized:
                Picker("Default calendar", selection: setting(\.defaultCalendarId)) {
                    Text("None").tag(String?.none)
                    ForEach(calendarGroups, id: \.0) { source, cals in
                        Section(source) {
                            ForEach(cals) { c in Text(c.title).tag(String?.some(c.id)) }
                        }
                    }
                }
                .pickerStyle(.navigationLink)
                Button("Create “Home” calendar") { Task { await createHomeCalendar() } }
            case .denied, .restricted:
                Text("Calendar access is off.").foregroundStyle(.secondary)
                if let url = TIK.systemSettingsURL { Link("Open iOS Settings", destination: url) }
            default:
                Button("Allow calendar access") { Task { await requestCalendarAccess() } }
            }
            Toggle("Also alert from Calendar", isOn: setting(\.alsoAlertFromCalendar))
            HStack {
                Text("This iPhone’s name")
                Spacer()
                TextField("iPhone", text: $nickname)
                    .multilineTextAlignment(.trailing)
                    .submitLabel(.done)
                    .onSubmit { commitNickname() }
            }
        } header: {
            Text("Calendar")
        } footer: {
            Text("Used in “Calendar events are managed on ‘\(nickname.isEmpty ? "iPhone" : nickname)’”. Google calendars appear here once the account is added in iPhone Settings › Calendar › Accounts.")
        }
    }

    private var calendarGroups: [(String, [CalendarInfo])] {
        var order: [String] = []
        var groups: [String: [CalendarInfo]] = [:]
        for c in calendars {
            if groups[c.sourceTitle] == nil { order.append(c.sourceTitle) }
            groups[c.sourceTitle, default: []].append(c)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    private func refreshCalendars() async {
        calendarStatus = await env.calendar.authorizationStatus()
        calendars = calendarStatus == .authorized ? await env.calendar.writableCalendars() : []
    }

    private func requestCalendarAccess() async {
        do { _ = try await env.calendar.requestAccess() } catch { errorText = error.localizedDescription }
        await refreshCalendars()
    }

    private func createHomeCalendar() async {
        do {
            let cal = try await env.calendar.createHomeCalendar()
            await refreshCalendars()
            updateSettings { $0.defaultCalendarId = cal.id }
        } catch {
            errorText = "Couldn’t create the calendar. \(error.localizedDescription)"
        }
    }

    private func commitNickname() {
        let n = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != settings.deviceNickname else { return }
        env.setDeviceNickname(n)
        updateSettings { $0.deviceNickname = n }
    }

    // MARK: iCloud

    private var iCloudSection: some View {
        Section {
            LabeledContent("Status", value: env.syncStatus.displayText)
            if let last = lastSyncDate {
                LabeledContent("Last synced", value: last.formatted(date: .abbreviated, time: .shortened))
            }
            switch env.syncStatus {
            case .iCloudOff:
                Text("Sign in to iCloud to back up and sync your home. Everything still works on this iPhone.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let url = TIK.systemSettingsURL { Link("Open iOS Settings", destination: url) }
            case .quotaExceeded:
                Text("Your iCloud storage is full. Changes stay on this iPhone until there’s space.")
                    .font(.footnote).foregroundStyle(.orange)
            case .error:
                Text("Your data is safe on this iPhone. Diagnostics has details.")
                    .font(.footnote).foregroundStyle(.secondary)
            default:
                EmptyView()
            }
            Button("Sync now") {
                Task { do { try await env.sync.syncNow() } catch { errorText = error.localizedDescription } }
            }
        } header: {
            Text("iCloud")
        }
    }

    private var lastSyncDate: Date? {
        if case .upToDate(let last) = env.syncStatus { return last }
        return nil
    }

    // MARK: About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Self.versionText)
            NavigationLink("Diagnostics") { DiagnosticsView() }
            NavigationLink("Acknowledgments") { AcknowledgmentsView() }
        }
    }

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "–"
        let b = info?["CFBundleVersion"] as? String ?? "–"
        return "\(v) (\(b))"
    }

    // MARK: Settings plumbing

    private func setting<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { settings[keyPath: keyPath] }, set: { v in updateSettings { $0[keyPath: keyPath] = v } })
    }

    private func updateSettings(_ change: (inout AppSettings) -> Void) {
        change(&settings)
        let snapshot = settings
        Task {
            await env.settings.save(snapshot)
            await env.reminders.replan(reason: .settingsChanged)
        }
    }
}

private struct AcknowledgmentsView: View {
    var body: some View {
        List {
            Section {
                Text("Map data © OpenStreetMap contributors, available under the Open Database License.")
            } header: { Text("OpenStreetMap") }
            Section {
                Text("GRDB.swift — SQLite toolkit by Gwendal Roué, MIT License.")
            } header: { Text("GRDB") }
            Section {
                Text("Polygon clipping follows the approach of Clipper2 by Angus Johnson (Boost Software License).")
            } header: { Text("Clipper2") }
        }
        .navigationTitle("Acknowledgments")
    }
}

#Preview {
    SettingsView().environment(AppEnvironment.preview())
}

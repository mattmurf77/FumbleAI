import SwiftUI
import HomeCore
import HomeCoreTesting

/// "Push notification" toggle + offset (FR-CHR-40…48). Notification permission is requested only when a reminder is
/// first switched on, after an in-app pre-prompt; if denied the toggle stays on (the chore still saves) and shows
/// "Notifications are off for Home" with an Open Settings link.
struct ReminderToggle: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var isOn: Bool
    @Binding var offsetMinutes: Int
    /// nil = all-day chore (fires at the Settings default time, 9:00 by default).
    var dueMinutes: MinuteOfDay?

    @State private var status: PermissionStatus?
    @State private var showPrePrompt = false
    @State private var allDayMinutes = Chore.defaultAllDayMinutes

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: { turnOn in
            if turnOn { Task { await switchOn() } } else { isOn = false }
        })) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Push notification", systemImage: "bell")
                if isOn {
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .task {
            status = await env.notificationAuth.authorizationStatus()
            allDayMinutes = await env.settings.load().defaultAllDayMinutes
        }
        .confirmationDialog("Get a reminder when this chore is due?", isPresented: $showPrePrompt, titleVisibility: .visible) {
            Button("Turn on reminders") { Task { await requestPermission() } }
            Button("Not now", role: .cancel) { isOn = false }
        } message: {
            Text("Home sends reminders from this iPhone. You can change this any time in Settings.")
        }

        if isOn {
            Picker("Remind me", selection: $offsetMinutes) {
                ForEach(ScheduleFormat.reminderOffsets, id: \.minutes) { Text($0.label).tag($0.minutes) }
            }
            if status == .denied {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Notifications are off for Home", systemImage: "bell.slash")
                        .foregroundStyle(.orange)
                    ScheduleSettingsLink()
                }
                .font(.footnote)
            }
        }
    }

    private var subtitle: String {
        let offsetText = offsetMinutes == 0 ? "" : " (\(ScheduleFormat.offsetLabel(offsetMinutes).lowercased()))"
        if let dueMinutes { return "On the due day at \(ScheduleFormat.time(dueMinutes))" + offsetText }
        return "On the due day at \(ScheduleFormat.time(allDayMinutes))" + offsetText
    }

    @MainActor
    private func switchOn() async {
        let s = await env.notificationAuth.authorizationStatus()
        status = s
        switch s {
        case .notDetermined:
            isOn = true
            showPrePrompt = true
        default:
            isOn = true                      // denied → still saves, with the warning row
        }
    }

    @MainActor
    private func requestPermission() async {
        _ = try? await env.notificationAuth.requestAuthorization()
        status = await env.notificationAuth.authorizationStatus()
    }
}

private struct ReminderTogglePreview: View {
    @State var on = true
    @State var offset = 0
    var body: some View {
        NavigationStack {
            Form { Section("Reminders") { ReminderToggle(isOn: $on, offsetMinutes: $offset, dueMinutes: 20 * 60) } }
        }
    }
}

#Preview {
    ReminderTogglePreview().environment(AppEnvironment.preview())
}

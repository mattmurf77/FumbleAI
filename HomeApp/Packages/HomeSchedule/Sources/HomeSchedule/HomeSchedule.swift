import Foundation
import HomeCore
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(EventKit)
import EventKit
#endif

// HomeSchedule — reminders and calendar (LLD §9.3–9.5). Owner fills: ReminderScheduler (actor, conforms to
// HomeCore.ReminderScheduling + NotificationAuthorizing; diffs NotificationPlanner output against pending
// requests), NotificationCenterProtocol, NotificationActions (CHORE_DUE: DONE / SNOOZE_1H), CalendarSync
// (actor, HomeCore.CalendarSyncing), CalendarStoreProtocol, RecurrenceToEK.
// Data access goes through HomeCore protocols (ChoreRepository etc.), injected by the app.

public enum HomeScheduleModule {
    public static let name = "HomeSchedule"
}

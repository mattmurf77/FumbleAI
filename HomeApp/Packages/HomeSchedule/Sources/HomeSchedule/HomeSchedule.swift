import Foundation
import HomeCore

// HomeSchedule — reminders and calendar (LLD §9.3–9.5).
//
// - `ReminderScheduler` (actor): `ReminderScheduling` + `NotificationAuthorizing`. Diffs `NotificationPlanner`
//   output against pending requests (`NotificationCenterProtocol`; live `UserNotificationCenterClient`).
// - `NotificationActions` / `NotificationActionHandler`: CHORE_DUE actions DONE / SNOOZE_1H and body taps.
// - `CalendarSync` (actor): `CalendarSyncing` over `CalendarStoreProtocol` (live `EventKitCalendarStore`).
// - `RecurrenceToEK`, `CalendarEventSpec`, `NotificationDiff`: pure mapping / diff logic (tested on Linux).
// - `KeychainDeviceIdentity`: owner-device id for the calendar model.
// Data access goes through HomeCore protocols (ChoreRepository etc.), injected by the app.

public enum HomeScheduleModule {
    public static let name = "HomeSchedule"
}

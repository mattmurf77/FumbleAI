import Foundation

/// A to-do: one-off (no rule) or recurring. LLD §3.2 `chore`, §9.
public struct Chore: SyncedModel {
    public static let recordType = RecordType.chore
    /// Default fire time for all-day chores (PRD Q-9): 9:00.
    public static let defaultAllDayMinutes = 540

    public var id: UUID
    public var propertyId: UUID
    public var scope: Scope
    public var title: String
    public var notes: String?
    public var assigneeId: UUID?
    /// nil = one-off task (§9.1).
    public var repeatRule: RepeatRule?
    /// Rule anchor.
    public var startOn: LocalDate
    /// nil = no due date / closed.
    public var nextDueOn: LocalDate?
    /// nil = all-day.
    public var dueMinutes: MinuteOfDay?
    public var remindEnabled: Bool
    /// Minutes before the due time (0 = at time).
    public var remindOffsetMin: Int
    public var calendarEnabled: Bool
    /// "Change filter" → furnace.
    public var linkedThingId: UUID?
    public var isPaused: Bool
    /// One-off completed, series finished, or archived.
    public var closedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: UUID = UUID(), propertyId: UUID, scope: Scope, title: String, notes: String? = nil,
                assigneeId: UUID? = nil, repeatRule: RepeatRule? = nil, startOn: LocalDate, nextDueOn: LocalDate? = nil,
                dueMinutes: MinuteOfDay? = nil, remindEnabled: Bool = false, remindOffsetMin: Int = 0,
                calendarEnabled: Bool = false, linkedThingId: UUID? = nil, isPaused: Bool = false, closedAt: Date? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id; self.propertyId = propertyId; self.scope = scope; self.title = title; self.notes = notes
        self.assigneeId = assigneeId; self.repeatRule = repeatRule; self.startOn = startOn; self.nextDueOn = nextDueOn
        self.dueMinutes = dueMinutes; self.remindEnabled = remindEnabled; self.remindOffsetMin = remindOffsetMin
        self.calendarEnabled = calendarEnabled; self.linkedThingId = linkedThingId; self.isPaused = isPaused
        self.closedAt = closedAt; self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }

    /// Open = not closed, not paused, not deleted.
    public var isOpen: Bool { closedAt == nil && !isPaused && deletedAt == nil }
    public var isRecurring: Bool { repeatRule != nil }

    public func isOverdue(today: LocalDate) -> Bool { isOpen && (nextDueOn.map { $0 < today } ?? false) }
    public func isDue(on day: LocalDate) -> Bool { isOpen && nextDueOn == day }
    /// Due within [today, today+6] (the To-Dos lens "this week").
    public func isDueThisWeek(today: LocalDate) -> Bool {
        guard isOpen, let d = nextDueOn else { return false }
        return d >= today && d <= today.adding(days: 6)
    }

    /// Deep link and calendar dedupe key: `home://chore/<uuid>`.
    public var deepLink: URL { URL(string: "\(AppConfig.urlScheme)://chore/\(id.uuidString.lowercased())")! }
}

/// Append-only completion (done or skipped). LLD §3.2 `chore_completion`.
public struct ChoreCompletion: SyncedModel {
    public static let recordType = RecordType.choreCompletion
    public enum Outcome: String, ForwardCompatibleEnum {
        case done, skipped, unknown
        public static var unknownCase: Outcome { .unknown }
    }
    public var id: UUID
    public var propertyId: UUID
    public var choreId: UUID
    /// The occurrence it satisfied.
    public var dueOn: LocalDate?
    public var doneAt: Date
    /// Local date of doneAt (for recurrence math).
    public var doneOn: LocalDate
    public var doneBy: UUID?
    public var outcome: Outcome
    public var note: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: UUID = UUID(), propertyId: UUID, choreId: UUID, dueOn: LocalDate?, doneAt: Date, doneOn: LocalDate,
                doneBy: UUID? = nil, outcome: Outcome = .done, note: String? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id; self.propertyId = propertyId; self.choreId = choreId; self.dueOn = dueOn; self.doneAt = doneAt
        self.doneOn = doneOn; self.doneBy = doneBy; self.outcome = outcome; self.note = note
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }
}

/// Synced link between a chore and its calendar event(s); owner-device model. LLD §3.2, §9.5.
public struct ChoreCalendarLink: SyncedModel {
    public static let recordType = RecordType.choreCalendarLink
    public enum Mode: String, ForwardCompatibleEnum {
        case series, single, unknown
        public static var unknownCase: Mode { .unknown }
    }
    /// == choreId (1:1).
    public var id: UUID
    public var propertyId: UUID
    public var choreId: UUID
    public var ownerDeviceId: String
    public var calendarTitle: String
    public var calendarSourceTitle: String?
    public var calendarIdentifier: String?
    public var eventExternalId: String?
    public var eventMode: Mode
    public var seriesSignature: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(choreId: UUID, propertyId: UUID, ownerDeviceId: String, calendarTitle: String,
                calendarSourceTitle: String? = nil, calendarIdentifier: String? = nil, eventExternalId: String? = nil,
                eventMode: Mode, seriesSignature: String? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = choreId; self.propertyId = propertyId; self.choreId = choreId; self.ownerDeviceId = ownerDeviceId
        self.calendarTitle = calendarTitle; self.calendarSourceTitle = calendarSourceTitle
        self.calendarIdentifier = calendarIdentifier; self.eventExternalId = eventExternalId; self.eventMode = eventMode
        self.seriesSignature = seriesSignature; self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }
}

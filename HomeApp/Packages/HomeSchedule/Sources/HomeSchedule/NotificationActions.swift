import Foundation
import HomeCore
#if canImport(UserNotifications)
import UserNotifications
#endif

/// What a notification response did.
public enum NotificationActionOutcome: Hashable, Sendable {
    /// DONE: the chore was completed (unassigned, PRD Q-5) and reminders replanned.
    case completed(UUID)
    /// SNOOZE_1H: a snooze was recorded and reminders replanned.
    case snoozed(UUID)
    /// Body tap: open this deep link (`home://chore/<uuid>`).
    case open(URL)
    case ignored
    case failed(String)
}

/// Platform-free handler for `CHORE_DUE` actions (LLD §9.3 "Actions"). The UNUserNotificationCenter delegate
/// (`NotificationActionHandler`) forwards to it; tests call it directly.
public struct NotificationActions: Sendable {
    public static let defaultActionIdentifier = "com.apple.UNNotificationDefaultActionIdentifier"
    public static let dismissActionIdentifier = "com.apple.UNNotificationDismissActionIdentifier"
    public static let snoozeSeconds: TimeInterval = 3600

    public let chores: any ChoreRepository
    public let reminders: any ReminderScheduling
    public let clock: any HomeClock

    public init(chores: any ChoreRepository, reminders: any ReminderScheduling, clock: any HomeClock = SystemClock()) {
        self.chores = chores; self.reminders = reminders; self.clock = clock
    }

    public func handle(actionIdentifier: String, requestIdentifier: String,
                       userInfo: [AnyHashable: Any]) async -> NotificationActionOutcome {
        let choreId = NotificationPayload.choreId(identifier: requestIdentifier, userInfo: userInfo)
        switch actionIdentifier {
        case PlannedNotification.doneAction:
            guard let choreId else { return .ignored }
            do {
                guard let chore = try await chores.chore(choreId), chore.isOpen else {
                    await reminders.replan(reason: .notificationAction)
                    return .ignored
                }
                _ = try await chores.complete(choreId, by: nil, at: clock.now)
                await reminders.replan(reason: .notificationAction)
                return .completed(choreId)
            } catch {
                return .failed("\(error)")
            }
        case PlannedNotification.snoozeAction:
            guard let choreId else { return .ignored }
            await reminders.snooze(chore: choreId, for: NotificationActions.snoozeSeconds)
            return .snoozed(choreId)
        case NotificationActions.defaultActionIdentifier:
            if let url = NotificationPayload.deepLink(identifier: requestIdentifier, userInfo: userInfo) { return .open(url) }
            return .ignored
        default:
            return .ignored
        }
    }
}

#if canImport(UserNotifications)
/// `UNUserNotificationCenterDelegate` for the app. Install it in `application(_:didFinishLaunchingWithOptions:)`
/// (before launch completes, so a Done tap that launched the app is delivered), then `configure` it once the
/// `AppEnvironment` exists. Responses that arrive before `configure` wait (up to ~4 s) for it.
public final class NotificationActionHandler: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var actions: NotificationActions?
    private var onOpen: (@MainActor @Sendable (URL) -> Void)?
    private var bufferedURLs: [URL] = []

    public override init() { super.init() }

    /// Sets this object as the center's delegate and registers the categories (Done / In 1 hour).
    public func install(on center: UNUserNotificationCenter = .current()) {
        center.delegate = self
        center.setNotificationCategories(NotificationCategories.all)
    }

    public func configure(actions: NotificationActions, onOpen: @escaping @MainActor @Sendable (URL) -> Void) {
        let buffered: [URL] = lock.withLock {
            self.actions = actions
            self.onOpen = onOpen
            defer { bufferedURLs = [] }
            return bufferedURLs
        }
        if !buffered.isEmpty {
            Task { @MainActor in for url in buffered { onOpen(url) } }
        }
    }

    private func waitForActions() async -> NotificationActions? {
        for _ in 0..<80 {
            if let a = lock.withLock({ actions }) { return a }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return lock.withLock { actions }
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let id = response.notification.request.identifier
        let info = response.notification.request.content.userInfo
        // userInfo is [AnyHashable: Any] (not Sendable); reduce it to strings before hopping tasks.
        var strings: [String: String] = [:]
        for (k, v) in info { if let k = k as? String, let v = v as? String { strings[k] = v } }
        let completion = UncheckedSendable(completionHandler)
        Task {
            if action == UNNotificationDefaultActionIdentifier {
                if let url = NotificationPayload.deepLink(identifier: id, userInfo: strings) { await self.open(url) }
            } else if let actions = await self.waitForActions() {
                _ = await actions.handle(actionIdentifier: action, requestIdentifier: id, userInfo: strings)
            }
            completion.value()
        }
    }

    private func open(_ url: URL) async {
        let handler: (@MainActor @Sendable (URL) -> Void)? = lock.withLock {
            if onOpen == nil { bufferedURLs.append(url) }
            return onOpen
        }
        if let handler { await MainActor.run { handler(url) } }
    }
}

private struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
#endif

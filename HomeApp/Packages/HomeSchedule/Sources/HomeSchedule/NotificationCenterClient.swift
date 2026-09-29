import Foundation
import HomeCore
#if canImport(UserNotifications)
import UserNotifications
#endif

/// A pending (or delivered) request as seen by the scheduler: its identifier and the stored content hash
/// (`userInfo["h"]`). Value-typed so the diff runs on Linux.
public struct PendingNotification: Hashable, Sendable {
    public var id: String
    public var contentHash: Int?
    public init(id: String, contentHash: Int?) { self.id = id; self.contentHash = contentHash }
}

/// The slice of `UNUserNotificationCenter` the scheduler needs (LLD §9.3). The live implementation is
/// `UserNotificationCenterClient`; tests and non-Apple builds use `InMemoryNotificationCenter`.
public protocol NotificationCenterProtocol: Sendable {
    func pendingRequests() async -> [PendingNotification]
    func deliveredIdentifiers() async -> [String]
    func add(_ notification: PlannedNotification) async throws
    func removePending(ids: [String]) async
    func removeDelivered(ids: [String]) async
    func authorizationStatus() async -> PermissionStatus
    func requestAuthorization() async throws -> Bool
    func setBadgeCount(_ count: Int) async
    /// Registers the `CHORE_DUE` (Done / In 1 hour) and `SYSTEM` categories.
    func registerCategories() async
}

/// Keys used in `UNNotificationContent.userInfo`.
public enum NotificationUserInfoKey {
    /// Stable content hash (`PlannedNotification.contentHash`).
    public static let hash = "h"
    /// Chore UUID string (present for chore reminders and snoozes).
    public static let choreId = "choreId"
    /// `home://chore/<uuid>` deep link.
    public static let deepLink = "deepLink"
}

public extension PlannedNotification {
    /// userInfo written on every request we schedule.
    var userInfo: [String: String] {
        var info: [String: String] = [NotificationUserInfoKey.hash: String(contentHash)]
        if let choreId { info[NotificationUserInfoKey.choreId] = choreId.uuidString.lowercased() }
        if let deepLink { info[NotificationUserInfoKey.deepLink] = deepLink.absoluteString }
        return info
    }
}

/// Parses the chore id out of a request identifier or its userInfo (snoozes use `sys:snooze-<n>` ids).
public enum NotificationPayload {
    public static func choreId(identifier: String, userInfo: [AnyHashable: Any]) -> UUID? {
        if let s = userInfo[NotificationUserInfoKey.choreId] as? String, let id = UUID(uuidString: s) { return id }
        return PlannedNotification.choreUUID(fromIdentifier: identifier)
    }

    public static func hash(from userInfo: [AnyHashable: Any]) -> Int? {
        if let i = userInfo[NotificationUserInfoKey.hash] as? Int { return i }
        if let s = userInfo[NotificationUserInfoKey.hash] as? String { return Int(s) }
        if let n = userInfo[NotificationUserInfoKey.hash] as? NSNumber { return n.intValue }
        return nil
    }

    public static func deepLink(identifier: String, userInfo: [AnyHashable: Any]) -> URL? {
        if let s = userInfo[NotificationUserInfoKey.deepLink] as? String, let url = URL(string: s) { return url }
        return choreId(identifier: identifier, userInfo: userInfo).map { ItemRef.chore($0).deepLink }
    }
}

// MARK: - In-memory (tests, previews, Linux)

/// Behaves like the system center for the parts the scheduler uses: pending requests keyed by id (adding an
/// existing id replaces it), delivered ids, badge and authorization.
public final class InMemoryNotificationCenter: NotificationCenterProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _pending: [String: PlannedNotification] = [:]
    private var _delivered: Set<String> = []
    private var _badge = 0
    private var _status: PermissionStatus
    private var _grantOnRequest: Bool
    private var _categoriesRegistered = false
    private var _addCount = 0
    private var _removeCount = 0

    public init(status: PermissionStatus = .authorized, grantOnRequest: Bool = true) {
        _status = status; _grantOnRequest = grantOnRequest
    }

    public var pending: [PlannedNotification] {
        lock.withLock { _pending.values.sorted { $0.id < $1.id } }
    }
    public var badge: Int { lock.withLock { _badge } }
    public var categoriesRegistered: Bool { lock.withLock { _categoriesRegistered } }
    /// Number of `add` calls so far (lets tests assert idempotent replans).
    public var addCount: Int { lock.withLock { _addCount } }
    public var removeCount: Int { lock.withLock { _removeCount } }

    /// Test hook: pretend these requests were delivered.
    public func markDelivered(_ ids: [String]) { lock.withLock { _delivered.formUnion(ids) } }
    public var delivered: Set<String> { lock.withLock { _delivered } }

    public func pendingRequests() async -> [PendingNotification] {
        lock.withLock { _pending.values.map { PendingNotification(id: $0.id, contentHash: $0.contentHash) } }
    }
    public func deliveredIdentifiers() async -> [String] { lock.withLock { Array(_delivered) } }
    public func add(_ notification: PlannedNotification) async throws {
        lock.withLock { _pending[notification.id] = notification; _addCount += 1 }
    }
    public func removePending(ids: [String]) async {
        lock.withLock { for id in ids { _pending[id] = nil }; _removeCount += ids.count }
    }
    public func removeDelivered(ids: [String]) async { lock.withLock { _delivered.subtract(ids) } }
    public func authorizationStatus() async -> PermissionStatus { lock.withLock { _status } }
    public func requestAuthorization() async throws -> Bool {
        lock.withLock {
            if _status == .notDetermined { _status = _grantOnRequest ? .authorized : .denied }
            return _status.isGranted
        }
    }
    public func setBadgeCount(_ count: Int) async { lock.withLock { _badge = count } }
    public func registerCategories() async { lock.withLock { _categoriesRegistered = true } }
}

// MARK: - UNUserNotificationCenter

#if canImport(UserNotifications)
/// Live center. All calls go to `UNUserNotificationCenter.current()`.
public struct UserNotificationCenterClient: NotificationCenterProtocol {
    public init() {}

    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    public func pendingRequests() async -> [PendingNotification] {
        let requests = await center.pendingNotificationRequests()
        return requests.map { PendingNotification(id: $0.identifier, contentHash: NotificationPayload.hash(from: $0.content.userInfo)) }
    }

    public func deliveredIdentifiers() async -> [String] {
        await center.deliveredNotifications().map { $0.request.identifier }
    }

    public func add(_ n: PlannedNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = n.title
        content.body = n.body
        content.sound = .default
        content.categoryIdentifier = n.categoryId
        content.threadIdentifier = n.threadId
        content.userInfo = n.userInfo
        // Floating components (no time zone) → fires at the same wall-clock time after travel / DST.
        var comps = n.fire
        comps.timeZone = nil
        comps.calendar = nil
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        try await center.add(UNNotificationRequest(identifier: n.id, content: content, trigger: trigger))
    }

    public func removePending(ids: [String]) async {
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    public func removeDelivered(ids: [String]) async {
        guard !ids.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    public func authorizationStatus() async -> PermissionStatus {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        case .provisional: return .provisional
        #if os(iOS)
        case .ephemeral: return .authorized
        #endif
        @unknown default: return .unknown
        }
    }

    public func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    public func setBadgeCount(_ count: Int) async {
        try? await center.setBadgeCount(count)
    }

    public func registerCategories() async {
        center.setNotificationCategories(NotificationCategories.all)
    }
}

/// `CHORE_DUE` (Done in the background, In 1 hour) and `SYSTEM`. LLD §9.3.
public enum NotificationCategories {
    public static var all: Set<UNNotificationCategory> {
        let done = UNNotificationAction(identifier: PlannedNotification.doneAction, title: "Done", options: [])
        let snooze = UNNotificationAction(identifier: PlannedNotification.snoozeAction, title: "In 1 hour", options: [])
        let chore = UNNotificationCategory(identifier: PlannedNotification.choreCategory, actions: [done, snooze],
                                           intentIdentifiers: [], options: [])
        let system = UNNotificationCategory(identifier: PlannedNotification.systemCategory, actions: [],
                                            intentIdentifiers: [], options: [])
        return [chore, system]
    }
}
#endif

/// The platform default: the system center on Apple platforms, an in-memory center elsewhere.
public func makeDefaultNotificationCenter() -> any NotificationCenterProtocol {
    #if canImport(UserNotifications)
    return UserNotificationCenterClient()
    #else
    return InMemoryNotificationCenter()
    #endif
}

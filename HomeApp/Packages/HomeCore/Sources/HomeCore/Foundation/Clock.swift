import Foundation

/// Injected time source. LLD §14.
public protocol Clock: Sendable {
    var now: Date { get }
    var calendar: Calendar { get }
}

public extension Clock {
    var today: LocalDate { LocalDate(now, calendar: calendar) }
}

/// Wall clock with the user's current Gregorian calendar.
public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
    public var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        c.locale = .current
        return c
    }
}

/// Fixed clock for tests and previews.
public struct FixedClock: Clock {
    public var now: Date
    public var calendar: Calendar
    public init(now: Date, timeZone: TimeZone = TimeZone(identifier: "America/New_York")!, firstWeekday: Int = 1) {
        self.now = now
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.firstWeekday = firstWeekday
        self.calendar = c
    }
    /// Noon on `date` in `timeZone`.
    public init(_ date: LocalDate, minutes: Int = 12 * 60, timeZone: TimeZone = TimeZone(identifier: "America/New_York")!) {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        self.init(now: date.date(atMinutes: minutes, calendar: c)!, timeZone: timeZone)
    }
}

/// This install's identity (Keychain-stored UUID + user-editable nickname). LLD §9.5 "Owner device".
public protocol DeviceIdentity: Sendable {
    var deviceId: String { get }
    var nickname: String { get }
}

public struct StaticDeviceIdentity: DeviceIdentity {
    public var deviceId: String
    public var nickname: String
    public init(deviceId: String = "preview-device", nickname: String = "iPhone") { self.deviceId = deviceId; self.nickname = nickname }
}

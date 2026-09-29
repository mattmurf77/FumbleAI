import Foundation
import HomeCore

/// Device-local `AppSettings` in `UserDefaults` (JSON under one key). Synced settings live on `Property`.
public final class SettingsStore: SettingsRepository, @unchecked Sendable {
    public static let key = "home.appSettings.v1"
    private let defaults: UserDefaults
    private let bus: DomainEventBus?
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<AppSettings>.Continuation] = [:]

    public init(defaults: UserDefaults = .standard, bus: DomainEventBus? = nil) {
        self.defaults = defaults
        self.bus = bus
    }

    public func load() async -> AppSettings { current() }

    func current() -> AppSettings {
        guard let data = defaults.data(forKey: Self.key), let s = try? HomeJSON.decoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return s
    }

    public func save(_ settings: AppSettings) async {
        if let data = try? HomeJSON.encoder().encode(settings) { defaults.set(data, forKey: Self.key) }
        for c in subscribers() { c.yield(settings) }
        bus?.publish(.settingsChanged)
    }

    private func subscribers() -> [AsyncStream<AppSettings>.Continuation] {
        lock.lock(); defer { lock.unlock() }
        return Array(continuations.values)
    }

    public func observe() -> AsyncStream<AppSettings> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { c in
            lock.lock(); continuations[id] = c; lock.unlock()
            c.yield(current())
            c.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.continuations[id] = nil; self.lock.unlock()
            }
        }
    }
}

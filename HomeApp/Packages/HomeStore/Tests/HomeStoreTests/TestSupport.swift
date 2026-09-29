import Foundation
import XCTest
import HomeCore
import HomeCoreTesting
import PlanKit
@testable import HomeStore

let today = LocalDate(2026, 9, 29)
let clock = FixedClock(LocalDate(2026, 9, 29))

/// A GRDB store and the in-memory oracle, both loaded with `SampleHome` and sharing one fixed clock.
struct Fixture {
    let store: HomeStore
    let oracle: InMemoryHome
    var pid: UUID { SampleHome.propertyId }

    static func sample() async throws -> Fixture {
        let snap = SampleHome.snapshot(today: today, now: clock.now)
        let store = try HomeStore.inMemory(clock: clock)
        try await seed(store, snap)
        let oracle = InMemoryHome(store: InMemoryStore(snap, clock: clock))
        return Fixture(store: store, oracle: oracle)
    }

    static func empty() throws -> HomeStore { try HomeStore.inMemory(clock: clock) }
}

/// Inserts every row of an in-memory snapshot (parents first) with `origin: .sync` (no outbox).
func seed(_ store: HomeStore, _ s: InMemorySnapshot) async throws {
    try await store.database.write(origin: .sync) { tx in
        for x in s.properties.values { try tx.save(x) }
        for x in s.people.values { try tx.save(x) }
        for x in s.levels.values { try tx.save(x) }
        for x in s.spaces.values { try tx.save(x) }
        for x in s.openings.values { try tx.save(x) }
        // Spots parent-first.
        var pending = Array(s.spots.values)
        var done = Set<UUID>()
        while !pending.isEmpty {
            let ready = pending.filter { $0.parentSpotId == nil || done.contains($0.parentSpotId!) }
            for x in ready { try tx.save(x); done.insert(x.id) }
            pending.removeAll { done.contains($0.id) }
            if ready.isEmpty { break }
        }
        for x in s.measurements.values { try tx.save(x) }
        for x in s.things.values { try tx.save(x) }
        for x in s.chores.values { try tx.save(x) }
        for x in s.completions.values { try tx.save(x) }
        for x in s.calendarLinks.values { try tx.save(x) }
        for x in s.projects.values { try tx.save(x) }
        for x in s.lineItems.values { try tx.save(x) }
        for x in s.inventory.values { try tx.save(x) }
        for x in s.attachments.values { try tx.save(x) }
    }
}

/// Waits for the first value of a stream satisfying `where` (default: the first value).
func first<T: Sendable>(_ stream: AsyncStream<T>, timeout: TimeInterval = 5, where pred: @escaping @Sendable (T) -> Bool = { _ in true }) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { g in
        g.addTask { for await v in stream where pred(v) { return v }; return nil }
        g.addTask { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)); return nil }
        guard let v = try await g.next() ?? nil else { g.cancelAll(); throw StreamTimeout() }
        g.cancelAll()
        return v
    }
}

func tmpFile(_ contents: String, ext: String) throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("att-\(UUID().uuidString).\(ext)")
    try Data(contents.utf8).write(to: u)
    return u
}
struct StreamTimeout: Error {}

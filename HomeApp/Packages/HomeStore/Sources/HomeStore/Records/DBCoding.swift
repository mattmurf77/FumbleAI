import Foundation
import GRDB
import HomeCore
import PlanKit

// Column encoding rules (LLD §1): UUIDs as lowercase TEXT, local dates as 'YYYY-MM-DD', instants as GRDB DATETIME
// text (UTC), booleans 0/1, enums as their raw TEXT, JSON columns via `HomeJSON` (sorted keys).

extension UUID {
    /// Lowercase 36-char text used for every id column and CloudKit recordName.
    var db: String { uuidString.lowercased() }
}

/// Column dictionary built by the record codecs. Values are `DatabaseValue` so rows can be diffed column by column.
struct Columns {
    private(set) var values: [String: DatabaseValue] = [:]
    init() {}

    subscript(_ key: String) -> DatabaseValue {
        get { values[key] ?? .null }
        set { values[key] = newValue }
    }

    mutating func set(_ key: String, _ v: (any DatabaseValueConvertible)?) { values[key] = v?.databaseValue ?? .null }
    mutating func set(_ key: String, uuid: UUID?) { values[key] = uuid.map { $0.db.databaseValue } ?? .null }
    mutating func set(_ key: String, date: LocalDate?) { values[key] = date.map { $0.description.databaseValue } ?? .null }
    mutating func set(_ key: String, bool: Bool) { values[key] = (bool ? 1 : 0).databaseValue }
    mutating func set(_ key: String, bool: Bool?) { values[key] = bool.map { ($0 ? 1 : 0).databaseValue } ?? .null }
    mutating func set<T: Encodable>(_ key: String, json: T?) throws {
        values[key] = try json.map { try HomeJSON.encodeString($0).databaseValue } ?? .null
    }
    /// Enum raw value. `.unknown` cannot be stored (the CHECK lists only known values), so local writes reject it.
    mutating func set<E: ForwardCompatibleEnum>(_ key: String, enum e: E) throws {
        guard e != E.unknownCase else { throw RepositoryError.invalid("\(key): unknown value cannot be saved") }
        values[key] = e.rawValue.databaseValue
    }
    mutating func set<E: ForwardCompatibleEnum>(_ key: String, enum e: E?) throws {
        if let e { try set(key, enum: e) } else { values[key] = .null }
    }
    mutating func set(_ key: String, scope: Scope) {
        values["scope"] = scope.kind.rawValue.databaseValue
        set("space_id", uuid: scope.spaceId)
        set("level_id", uuid: scope.levelId)
        _ = key
    }
    mutating func set(_ prefix: String, pin: Vec2?) {
        set("\(prefix)_x", pin?.x); set("\(prefix)_y", pin?.y)
    }
    mutating func setTimestamps<M: SyncedModel>(_ m: M) {
        set("created_at", m.createdAt); set("updated_at", m.updatedAt); set("deleted_at", m.deletedAt)
    }
}

extension Row {
    func uuid(_ c: String) throws -> UUID {
        guard let s: String = self[c], let u = UUID(uuidString: s) else { throw RepositoryError.invalid("bad uuid in \(c)") }
        return u
    }
    func uuidOpt(_ c: String) -> UUID? { (self[c] as String?).flatMap(UUID.init(uuidString:)) }
    func localDate(_ c: String) throws -> LocalDate {
        guard let s: String = self[c], let d = LocalDate(string: s) else { throw RepositoryError.invalid("bad date in \(c)") }
        return d
    }
    func localDateOpt(_ c: String) -> LocalDate? { (self[c] as String?).flatMap(LocalDate.init(string:)) }
    func bool(_ c: String) -> Bool { (self[c] as Int64?) ?? 0 != 0 }
    func boolOpt(_ c: String) -> Bool? { (self[c] as Int64?).map { $0 != 0 } }
    func enumValue<E: ForwardCompatibleEnum>(_ c: String) -> E { E(storedValue: (self[c] as String?) ?? "") }
    func enumOpt<E: ForwardCompatibleEnum>(_ c: String) -> E? { (self[c] as String?).map(E.init(storedValue:)) }
    func json<T: Decodable>(_ c: String, _ t: T.Type) throws -> T? {
        guard let s: String = self[c] else { return nil }
        return try HomeJSON.decode(T.self, from: s)
    }
    func vec(_ prefix: String) -> Vec2? {
        guard let x: Double = self["\(prefix)_x"], let y: Double = self["\(prefix)_y"] else { return nil }
        return Vec2(x: x, y: y)
    }
    func scope() throws -> Scope {
        let kind = Scope.Kind(storedValue: (self["scope"] as String?) ?? "")
        return try Scope(kind: kind, spaceId: uuidOpt("space_id"), levelId: uuidOpt("level_id"))
    }
    func date(_ c: String) -> Date { (self[c] as Date?) ?? Date(timeIntervalSince1970: 0) }
}

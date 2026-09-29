import Foundation
import HomeCore
import HomeStore

/// Three-way column overlay (LLD §5.4, HLD §5.3): start from the server row, overlay the columns this device changed
/// since its last successful send (`sync_outbox.changed_fields`), then apply the per-record exceptions.
public enum MergePolicy {
    /// Columns that always move together (location/event consistency). If any is locally changed, all come from local.
    static func groups(_ t: RecordType) -> [[String]] {
        let scope = ["scope", "space_id", "level_id"]
        let pin = ["pin_x", "pin_y"]
        switch t {
        case .inventoryItem: return [scope + ["storage_spot_id"]]
        case .chore, .project: return [scope]
        case .thing: return [scope, pin, ["purchase_price_cents", "currency_code"]]
        case .choreCalendarLink:
            return [["owner_device_id", "calendar_title", "calendar_source_title", "calendar_identifier", "event_external_id",
                     "event_mode", "series_signature"]]
        case .opening: return [["ax", "ay", "bx", "by"]]
        case .measurement: return [pin, ["seg_ax", "seg_ay", "seg_bx", "seg_by"]]
        case .storageSpot: return [pin]
        case .property: return [["address_line", "locality", "region", "postal_code", "country_code", "latitude", "longitude"]]
        default: return []
        }
    }

    /// Merged row for `type`. `server` is the fetched/conflicting server row, `local` the current local row,
    /// `changed` the outbox changed-field set. `today` is the fallback for a done project without a completion date.
    public static func merge(_ type: RecordType, server: SyncRow, local: SyncRow, changed: Set<String>, today: LocalDate) -> SyncRow {
        var merged = server
        var overlay = changed.filter { !$0.contains(".") }
        // Groups.
        for g in groups(type) where !overlay.isDisjoint(with: g) { overlay.formUnion(g) }
        // Project: status + completed_on are paired.
        if type == .project, !overlay.isDisjoint(with: ["status", "completed_on"]) { overlay.formUnion(["status", "completed_on"]) }
        // Thing attributes: key-level overlay.
        var attributeKeys: Set<String> = []
        if type == .thing {
            attributeKeys = Set(changed.filter { $0.hasPrefix("attributes_json.") }.map { String($0.dropFirst("attributes_json.".count)) })
            if !attributeKeys.isEmpty { overlay.remove("attributes_json") }
        }
        for c in overlay where c != "updated_at" && c != "created_at" {
            if let v = local[c] { merged[c] = v }
        }
        if !attributeKeys.isEmpty {
            merged["attributes_json"] = mergeAttributes(server: server["attributes_json"], local: local["attributes_json"], keys: attributeKeys)
        }
        // Timestamps: updated_at = max, created_at = min.
        if let l = local["updated_at"]?.dateValue {
            let s = server["updated_at"]?.dateValue
            merged["updated_at"] = .date(max(l, s ?? l))
        }
        if let l = local["created_at"]?.dateValue {
            let s = server["created_at"]?.dateValue
            merged["created_at"] = .date(min(l, s ?? l))
        }
        // deleted_at: delete wins unless the local side changed it (explicit restore or local delete) — the overlay
        // above already implements that; nothing else to do.
        // Project: done needs completed_on.
        if type == .project, merged["status"] == .string("done"), merged["completed_on"]?.isNull ?? true {
            let other = [server["completed_on"], local["completed_on"]].compactMap { $0 }.first { !$0.isNull }
            merged["completed_on"] = other ?? .string(today.description)
        }
        return merged
    }

    static func mergeAttributes(server: SyncValue?, local: SyncValue?, keys: Set<String>) -> SyncValue {
        func parse(_ v: SyncValue?) -> [String: JSONValue] {
            guard let s = v?.stringValue else { return [:] }
            return (try? HomeJSON.decode([String: JSONValue].self, from: s)) ?? [:]
        }
        var out = parse(server)
        let l = parse(local)
        for k in keys { out[k] = l[k] }
        return (try? HomeJSON.encodeString(out)).map(SyncValue.string) ?? (server ?? .string("{}"))
    }
}

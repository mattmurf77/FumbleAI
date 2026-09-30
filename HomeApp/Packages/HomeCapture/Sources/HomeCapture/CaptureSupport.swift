import Foundation
import PlanKit
import HomeCore

// HomeCapture — the plan-creation paths and receipt OCR (LLD §6.9, §6.10, §6.12, §15). Every path outputs a
// HomeCore.PlanDraft. Public entry points:
//   RoomPlanImporter  (RoomPlanImporting)      — RoomPlanImporter.swift, RoomPlanConversion.swift
//   RoughInGenerator  (RoughInGenerating)      — RoughInGenerator.swift
//   BlockTemplates    (BlockTemplating)        — BlockTemplates.swift
//   PhotoTraceCalibrator (PhotoTraceCalibrating) — PhotoTraceCalibrator.swift
//   ReceiptParser     (ReceiptParsing, pure)   — ReceiptParser.swift
//   ReceiptReader     (ReceiptReading, Vision) — ReceiptReader.swift

public enum HomeCaptureModule {
    public static let name = "HomeCapture"
}

/// Shared naming / construction helpers for the capture paths.
public enum CaptureNaming {
    /// "1st Floor", "2nd Floor", "3rd Floor", "4th Floor" (index 0 = ground), matching `Level.name` docs.
    public static func floorName(index: Int) -> String {
        let n = index + 1
        let suffix: String
        switch (n % 10, n % 100) {
        case (_, 11...13): suffix = "th"
        case (1, _): suffix = "st"
        case (2, _): suffix = "nd"
        case (3, _): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix) Floor"
    }

    /// Numbers duplicate names in order: ["Bedroom", "Bedroom"] → ["Bedroom", "Bedroom 2"] (§6.12 step 7c).
    public static func numberDuplicates(_ names: [String]) -> [String] {
        var seen: [String: Int] = [:]
        var taken = Set<String>()
        var out: [String] = []
        for n in names {
            let c = (seen[n] ?? 0) + 1
            seen[n] = c
            var candidate = c == 1 ? n : "\(n) \(c)"
            var k = c
            while taken.contains(candidate) { k += 1; candidate = "\(n) \(k)" }
            taken.insert(candidate)
            out.append(candidate)
        }
        return out
    }
}

/// Deterministic UUIDs for generated drafts so that the same input produces an identical `PlanDraft`
/// (golden tests, FR-PLN-12). Not used for anything persisted: `PlanCommitting` maps temp ids to fresh UUIDs.
struct DeterministicIDs {
    private var counter: UInt64 = 0
    private let seed: UInt64
    init(seed: UInt64) { self.seed = seed }

    mutating func next() -> UUID {
        counter += 1
        var h: UInt64 = 0xcbf2_9ce4_8422_2325 ^ seed
        for byte in withUnsafeBytes(of: counter.littleEndian, Array.init) { h ^= UInt64(byte); h = h &* 0x0000_0100_0000_01B3 }
        let hi = h, lo = h &* 0x9E37_79B9_7F4A_7C15 ^ counter
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { bytes[i] = UInt8(truncatingIfNeeded: hi >> (8 * UInt64(i))); bytes[8 + i] = UInt8(truncatingIfNeeded: lo >> (8 * UInt64(i))) }
        bytes[6] = (bytes[6] & 0x0F) | 0x40   // version 4 layout
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// FNV-1a over a string (stable across launches, unlike `hashValue`).
    static func seed(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x0000_0100_0000_01B3 }
        return h
    }
}

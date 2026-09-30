import Foundation

/// String-backed enums that decode unknown raw values (written by a newer app version) to `.unknown`
/// instead of throwing. LLD §1 "Enums". Conformers must declare a `case unknown`.
///
/// Note: decoding to `.unknown` loses the original string in the struct. Sync mappers (HomeSync) must keep the
/// original record field when writing back a row whose enum is `.unknown` (see CONTRACT.md).
public protocol ForwardCompatibleEnum: RawRepresentable, Codable, Hashable, Sendable, CaseIterable where RawValue == String {
    static var unknownCase: Self { get }
}

extension ForwardCompatibleEnum {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? Self.unknownCase
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    /// Parses a stored raw value, mapping unknown strings to `.unknown`.
    public init(storedValue: String) { self = Self(rawValue: storedValue) ?? Self.unknownCase }

    /// All cases except `.unknown` — use for pickers.
    public static var knownCases: [Self] { allCases.filter { $0 != unknownCase } }
}

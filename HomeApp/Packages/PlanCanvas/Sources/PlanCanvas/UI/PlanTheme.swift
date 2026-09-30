#if canImport(SwiftUI)
import SwiftUI
import HomeCore

/// Color tokens from the mockup (`mockups/index.html` `:root`), light and dark. The dark palette inverts paper and
/// walls (`--wall` becomes light) as in `seven-views.md` §8 "Theme".
public struct PlanTheme: Sendable {
    public var paper: Color, wall: Color, room: Color, roomAlt: Color, hatch: Color
    public var ink: Color, ink2: Color, ink3: Color, dim: Color, grid: Color
    public var accent: Color, onAccent: Color, accentSoft: Color
    public var tint1: Color, tint2: Color, tint3: Color
    public var danger: Color, dangerSoft: Color, warn: Color, warnSoft: Color, ok: Color
    public var surface: Color, surface2: Color, separator: Color
    public var lawn: Color, hardscape: Color, mulch: Color, deck: Color, water: Color, zone: Color
    public var isDark: Bool

    public static let light = PlanTheme(
        paper: .hex(0xF3F4F5), wall: .hex(0x26292E), room: .hex(0xFFFFFF), roomAlt: .hex(0xF1F1EF), hatch: .hex(0xC6C9CD),
        ink: .hex(0x16181B), ink2: .hex(0x5E646B), ink3: .hex(0x979DA5), dim: .hex(0x6B7078), grid: .rgba(30, 90, 168, 0.10),
        accent: .hex(0x1E5AA8), onAccent: .hex(0xFFFFFF), accentSoft: .rgba(30, 90, 168, 0.11),
        tint1: .rgba(30, 90, 168, 0.07), tint2: .rgba(30, 90, 168, 0.16), tint3: .rgba(30, 90, 168, 0.30),
        danger: .hex(0xC23A2E), dangerSoft: .rgba(194, 58, 46, 0.11), warn: .hex(0xA2670F), warnSoft: .rgba(190, 125, 20, 0.13), ok: .hex(0x2B7A4B),
        surface: .hex(0xFFFFFF), surface2: .hex(0xF1F2F4), separator: .rgba(60, 60, 67, 0.16),
        lawn: .hex(0xCFE8C4), hardscape: .hex(0xD9D9D9), mulch: .hex(0xE6D3B3), deck: .hex(0xDCC7A8), water: .hex(0xBFDDF2), zone: .hex(0xE4E7EA),
        isDark: false)

    public static let dark = PlanTheme(
        paper: .hex(0x0A0B0D), wall: .hex(0xD6D9DD), room: .hex(0x141619), roomAlt: .hex(0x1A1D21), hatch: .hex(0x353A40),
        ink: .hex(0xF2F3F5), ink2: .hex(0xA1A7AE), ink3: .hex(0x6C737B), dim: .hex(0x9AA0A8), grid: .rgba(110, 162, 236, 0.10),
        accent: .hex(0x6EA2EC), onAccent: .hex(0x08182C), accentSoft: .rgba(110, 162, 236, 0.16),
        tint1: .rgba(110, 162, 236, 0.10), tint2: .rgba(110, 162, 236, 0.22), tint3: .rgba(110, 162, 236, 0.38),
        danger: .hex(0xFF6B5E), dangerSoft: .rgba(255, 107, 94, 0.16), warn: .hex(0xE8A544), warnSoft: .rgba(232, 165, 68, 0.16), ok: .hex(0x5CC98A),
        surface: .hex(0x1C1C1E), surface2: .hex(0x26272A), separator: .rgba(120, 120, 128, 0.32),
        lawn: .hex(0x2B4527), hardscape: .hex(0x34373B), mulch: .hex(0x45382A), deck: .hex(0x4A3B2C), water: .hex(0x1E3A52), zone: .hex(0x23272C),
        isDark: true)

    public static func forScheme(_ scheme: ColorScheme) -> PlanTheme { scheme == .dark ? .dark : .light }

    public func fill(_ f: RoomFill) -> Color {
        switch f {
        case .room: return room
        case .roomAlt, .footprint: return roomAlt
        case .lawn: return lawn
        case .hardscape: return hardscape
        case .mulch: return mulch
        case .deck: return deck
        case .water: return water
        case .zone: return zone
        }
    }

    public func tint(_ t: TintLevel) -> Color? {
        switch t { case .none: return nil; case .low: return tint1; case .medium: return tint2; case .high: return tint3 }
    }

    public func edge(_ r: EdgeStyle.Role) -> Color { r == .danger ? danger : accent }

    /// (background, foreground, hairline) for a chip.
    public func chipColors(_ s: ChipStyle) -> (Color, Color, Color?) {
        switch s {
        case .accent: return (accent, onAccent, nil)
        case .danger: return (danger, .white, nil)
        case .neutral: return (room, ink, wall.opacity(0.55))
        case .soft: return (accentSoft, accent, nil)
        }
    }

    public func text(_ r: TextRun.Role) -> Color {
        switch r { case .normal: return ink; case .secondary: return ink2; case .danger: return danger; case .accent: return accent; case .warn: return warn }
    }

    /// Person color from a stored hex ("#2F6FDE"), falling back to the accent.
    public func personColor(_ hex: String?) -> Color { hex.flatMap(Color.init(hexString:)) ?? accent }
}

public extension Color {
    static func hex(_ v: UInt32, opacity: Double = 1) -> Color {
        Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: opacity)
    }
    static func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Color {
        Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
    }
    /// "#RRGGBB" / "RRGGBB".
    init?(hexString: String) {
        let s = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self = Color.hex(v)
    }
}

private struct PlanThemeKey: EnvironmentKey {
    static let defaultValue: PlanTheme? = nil
}

public extension EnvironmentValues {
    /// Optional override; views fall back to `PlanTheme.forScheme(colorScheme)`.
    var planTheme: PlanTheme? {
        get { self[PlanThemeKey.self] }
        set { self[PlanThemeKey.self] = newValue }
    }
}
#endif

#if canImport(SwiftUI)
import SwiftUI
import HomeCore
#if canImport(UIKit)
import UIKit
#endif

/// Resolves the theme from the environment (override or color scheme).
struct ThemeReader<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.planTheme) private var override
    @ViewBuilder let content: (PlanTheme) -> Content
    var body: some View { content(override ?? PlanTheme.forScheme(scheme)) }
}

/// SF Symbol with a fallback for names missing on older systems.
public func planSymbolName(_ name: String) -> String {
    #if canImport(UIKit)
    return UIImage(systemName: name) != nil ? name : "shippingbox"
    #else
    return name
    #endif
}

/// The per-room "+" (28 pt visible, 44 pt hit area). Quiet rooms get a grey outline.
public struct AddButtonView: View {
    let isQuiet: Bool
    let action: () -> Void
    public init(isQuiet: Bool = false, action: @escaping () -> Void) { self.isQuiet = isQuiet; self.action = action }

    public var body: some View {
        ThemeReader { theme in
            Button(action: action) {
                ZStack {
                    Circle().fill(theme.room)
                    Circle().strokeBorder(isQuiet ? theme.ink3 : theme.accent, lineWidth: 1.3)
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(isQuiet ? theme.ink3 : theme.accent)
                }
                .frame(width: LabelLayout.addVisibleSize, height: LabelLayout.addVisibleSize)
                .frame(width: LabelLayout.addHitSize, height: LabelLayout.addHitSize)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)   // the room's accessibility element carries "Add item"
        }
    }
}

/// Capsule chip: 11 pt semibold tabular figures (`seven-views.md` §0 "Chips").
public struct ChipView: View {
    let chip: Chip
    public init(_ chip: Chip) { self.chip = chip }

    public var body: some View {
        ThemeReader { theme in
            let (bg, fg, line) = theme.chipColors(chip.style)
            HStack(spacing: 4) {
                if let dot = chip.dot {
                    Circle().fill(dot == .warn ? theme.warn : theme.danger).frame(width: 6, height: 6)
                }
                Text(chip.text)
                    .font(.system(size: 11, weight: chip.emphasized ? .bold : .semibold).monospacedDigit())
                    .foregroundColor(fg)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Capsule().fill(bg))
            .overlay(Capsule().strokeBorder(line ?? .clear, lineWidth: 0.6))
            .accessibilityHidden(true)
        }
    }
}

/// A Things glyph / storage-spot pin, or a count bubble when pins cluster.
public struct PinView: View {
    let placement: OverlayLayout.PinPlacement
    public init(_ placement: OverlayLayout.PinPlacement) { self.placement = placement }

    public var body: some View {
        ThemeReader { theme in
            if placement.isCluster {
                Text("\(placement.count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundColor(theme.onAccent)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(Circle().fill(theme.accent))
                    .accessibilityHidden(true)
            } else if let pin = placement.pins.first {
                let planned = pin.isPlanned
                ZStack {
                    Circle().fill(theme.room)
                    Circle().strokeBorder(theme.accent, style: StrokeStyle(lineWidth: 1, dash: planned ? [2, 2] : []))
                    Image(systemName: planSymbolName(pin.symbol))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.accent)
                }
                .frame(width: 22, height: 22)
                .overlay(alignment: .topTrailing) {
                    if pin.kind == .spot && pin.count > 0 {
                        Text("\(pin.count)")
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                            .foregroundColor(theme.onAccent)
                            .padding(.horizontal, 3)
                            .background(Capsule().fill(theme.accent))
                            .offset(x: 8, y: -6)
                    }
                }
                .accessibilityHidden(true)
            }
        }
    }
}

/// "Whole house · N" / "This floor · N" chips under the pills (FR-CNV-25).
public struct ScopeChipsView: View {
    public enum Target: Hashable, Sendable { case wholeHouse, thisFloor }
    let decorations: LensDecorations
    let onTap: (Target) -> Void
    public init(decorations: LensDecorations, onTap: @escaping (Target) -> Void) { self.decorations = decorations; self.onTap = onTap }

    public var body: some View {
        ThemeReader { theme in
            HStack(spacing: 6) {
                if let n = decorations.wholeHouseCount { chip("Whole house · \(n)", theme) { onTap(.wholeHouse) } }
                if let n = decorations.thisFloorCount { chip("This floor · \(n)", theme) { onTap(.thisFloor) } }
            }
        }
    }

    private func chip(_ text: String, _ theme: PlanTheme, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundColor(theme.ink)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(theme.surface))
                .overlay(Capsule().strokeBorder(theme.separator, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

/// The bottom summary strip (two lines + optional spent-share bar).
public struct SummaryStripView: View {
    let footer: FooterSummary
    let onTap: (() -> Void)?
    public init(footer: FooterSummary, onTap: (() -> Void)? = nil) { self.footer = footer; self.onTap = onTap }

    public var body: some View {
        ThemeReader { theme in
            Button { onTap?() } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        runs(footer.primary, theme).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        if !footer.secondary.isEmpty {
                            runs(footer.secondary, theme).font(.system(size: 13)).lineLimit(1)
                        }
                        if let f = footer.barFraction {
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(theme.surface2)
                                    Capsule().fill(theme.accent).frame(width: g.size.width * CGFloat(min(max(f, 0), 1)))
                                }
                            }
                            .frame(height: 6)
                            .padding(.top, 5)
                        }
                    }
                    Spacer(minLength: 0)
                    if onTap != nil {
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(theme.ink3)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(minHeight: 66)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(theme.isDark ? 0 : 0.06), radius: 7, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(onTap == nil)
            .accessibilityElement(children: .combine)
        }
    }

    private func runs(_ runs: [TextRun], _ theme: PlanTheme) -> Text {
        runs.reduce(Text("")) { acc, r in acc + Text(r.text).foregroundColor(theme.text(r.role)) }
    }
}
#endif

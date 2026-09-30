import SwiftUI
import PlanKit
import HomeCore

/// Lightweight read-only drawing of a `LevelDraft` for the review screen (the real canvas is PlanCanvas, which renders
/// committed levels). Fills by space type, dashed outlines for approximate rooms, doors/windows as short strokes,
/// room names at the pole of inaccessibility, warning rooms outlined in orange.
struct DraftPlanPreview: View {
    let level: LevelDraft
    var highlighted: Set<UUID> = []

    var body: some View {
        Canvas { ctx, size in
            let b = level.bounds
            guard !b.isNull, b.width > 0, b.height > 0 else { return }
            let pad: CGFloat = 16
            let scale = min((size.width - 2 * pad) / b.width, (size.height - 2 * pad) / b.height)
            let ox = (size.width - b.width * scale) / 2, oy = (size.height - b.height * scale) / 2
            func pt(_ v: Vec2) -> CGPoint { CGPoint(x: ox + (v.x - b.minX) * scale, y: oy + (v.y - b.minY) * scale) }

            for s in level.spaces {
                var path = Path()
                path.addLines(s.polygon.vertices.map(pt))
                path.closeSubpath()
                ctx.fill(path, with: .color(Self.fill(for: s)))
                let warn = highlighted.contains(s.tempId)
                ctx.stroke(path, with: .color(warn ? .orange : .primary.opacity(0.75)),
                           style: StrokeStyle(lineWidth: warn ? 2.5 : 1.5, dash: s.isApproximate ? [6, 4] : []))
            }
            for o in level.openings {
                var p = Path()
                p.move(to: pt(o.segment.a)); p.addLine(to: pt(o.segment.b))
                ctx.stroke(p, with: .color(o.kind == .window ? .blue : Color(white: 0.97)), lineWidth: 4)
            }
            for s in level.spaces {
                let pole = PolyLabel.pole(of: s.polygon)
                guard pole.radius * scale > 14 else { continue }
                let text = Text(s.name).font(.system(size: max(9, min(13, pole.radius * scale / 3)), weight: .medium))
                ctx.draw(text, at: pt(pole.point))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(level.name) plan preview")
        .accessibilityValue(level.spaces.map(\.name).joined(separator: ", "))
    }

    static func fill(for s: SpaceDraft) -> Color {
        if let hex = s.colorHex, let c = color(hex: hex) { return c.opacity(0.7) }
        switch s.spaceType {
        case .kitchen, .dining: return Color.orange.opacity(0.14)
        case .bedroom: return Color.blue.opacity(0.12)
        case .bathroom, .halfBath, .laundry: return Color.teal.opacity(0.16)
        case .living, .family, .office: return Color.green.opacity(0.12)
        case .hall, .stairs, .closet, .storage, .utility: return Color.gray.opacity(0.14)
        case .garage: return Color.gray.opacity(0.22)
        default: return Color.secondary.opacity(0.08)
        }
    }

    static func color(hex: String) -> Color? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

#Preview("Draft preview") {
    DraftPlanPreview(level: StubPreviewDrafts.rough().levels[0]).frame(height: 300).padding()
}

/// Preview data built from the in-memory stand-ins (no HomeCapture dependency in previews).
@MainActor
enum StubPreviewDrafts {
    static func rough() -> PlanDraft {
        AppEnvironment.preview(sample: false).roughIn.draft(RoughInInput(floors: 2, hasBasement: false, approxSqFt: 2000, bedrooms: 3, bathrooms: 2.5))
    }
}

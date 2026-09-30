import SwiftUI
import HomeCore
import HomeCoreTesting

/// Live fit-check banner (spec 07 FR-MSR-21..28, LLD §10). Recomputed on every render from the thing's current
/// (unsaved) dimensions with HomeCore `FitChecker`; results are never stored and never block saving.
struct FitBanner: View {
    @Environment(AppEnvironment.self) private var env
    let item: Dims3
    let policy: FitPolicy
    /// The "goes into" measurement (nil = none chosen).
    let target: HomeMeasurement?
    /// Measurements flagged as delivery path (front door…).
    let deliveryPaths: [HomeMeasurement]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let target {
                let r = env.fitChecker.check(item: item, into: target.dims, policy: policy)
                verdictHeader(r.overall, title: headline(r.overall, label: target.label), message: r.message)
                axisLines(r)
                if clearanceText != nil {
                    Text(clearanceText ?? "").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Label("Choose where this goes to check the fit", systemImage: "ruler")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(deliveryPaths) { door in
                let r = env.fitChecker.passThrough(item: item, door: door.dims)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol(r.overall)).foregroundStyle(tint(r.overall))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pathTitle(r.overall, door: door.label)).font(.subheadline.weight(.medium))
                        Text(r.message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 4)
    }

    private var clearanceText: String? {
        let c = policy.clearance
        guard c.width > 0 || c.depth > 0 || c.height > 0 else { return nil }
        let f = { (v: Double) in HomeLengthFormatter.formatInches(v) }
        var parts: [String] = []
        if c.width > 0 { parts.append("\(f(c.width)) width") }
        if c.depth > 0 { parts.append("\(f(c.depth)) depth") }
        if c.height > 0 { parts.append("\(f(c.height)) height") }
        return "Includes clearance: " + parts.joined(separator: ", ") + "."
    }

    private func verdictHeader(_ o: FitResult.Overall, title: String, message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol(o)).foregroundStyle(tint(o))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(tint(o))
                Text(message).font(.subheadline)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func axisLines(_ r: FitResult) -> some View {
        let lines = [TIK.axisText(r.width, axis: "Width"), TIK.axisText(r.depth, axis: "Depth"), TIK.axisText(r.height, axis: "Height")]
            .compactMap { $0 }
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines, id: \.self) { Text($0).font(.caption) }
                if r.rotated { Text("Fits if rotated (turned sideways)").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func headline(_ o: FitResult.Overall, label: String) -> String {
        switch o {
        case .fits: return "Fits the \(label)"
        case .tight: return "Tight in the \(label)"
        case .noFit: return "Won’t fit the \(label)"
        case .unknown: return "Can’t check the \(label) yet"
        }
    }

    private func pathTitle(_ o: FitResult.Overall, door: String) -> String {
        switch o {
        case .fits: return "Fits through \(door)"
        case .tight: return "Tight through \(door)"
        case .noFit: return "Won’t fit through \(door)"
        case .unknown: return "\(door): add dimensions"
        }
    }

    private func symbol(_ o: FitResult.Overall) -> String {
        switch o {
        case .fits: return "checkmark.circle.fill"
        case .tight: return "exclamationmark.triangle.fill"
        case .noFit: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private func tint(_ o: FitResult.Overall) -> Color {
        switch o {
        case .fits: return .green
        case .tight: return .orange
        case .noFit: return .red
        case .unknown: return .secondary
        }
    }
}

#Preview("Won't fit + door") {
    let fridgeOpening = HomeMeasurement(propertyId: SampleHome.propertyId, label: "Fridge opening", kind: .opening,
                                        spaceId: SampleHome.kitchenId, dims: Dims3(width: 32, depth: 40, height: 72))
    let door = HomeMeasurement(propertyId: SampleHome.propertyId, label: "Front door", kind: .door,
                               spaceId: SampleHome.hallId, dims: Dims3(width: 36, height: 80), isDeliveryPath: true)
    return List {
        FitBanner(item: Dims3(width: 35.75, depth: 30, height: 70),
                  policy: FitPolicy.default(templateKey: "refrigerator", category: .appliance),
                  target: fridgeOpening, deliveryPaths: [door])
        FitBanner(item: Dims3(width: 84, depth: 38, height: 34),
                  policy: FitPolicy.default(templateKey: "sofa", category: .furniture),
                  target: nil, deliveryPaths: [door])
    }
    .environment(AppEnvironment.preview())
}

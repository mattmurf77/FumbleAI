import Foundation

public enum AxisVerdict: Hashable, Sendable {
    case fits(spare: Double), tight(spare: Double), tooBig(by: Double), protrudes(by: Double), unknown
    var severity: Int {
        switch self { case .unknown: return -1; case .fits: return 0; case .tight, .protrudes: return 1; case .tooBig: return 2 }
    }
    /// Spare inches (negative when too big / protruding); nil when unknown.
    public var spare: Double? {
        switch self {
        case .fits(let s), .tight(let s): return s
        case .tooBig(let b), .protrudes(let b): return -b
        case .unknown: return nil
        }
    }
}

public struct FitResult: Hashable, Sendable {
    public enum Overall: String, Hashable, Sendable { case fits, tight, noFit, unknown }
    public var width: AxisVerdict
    public var depth: AxisVerdict
    public var height: AxisVerdict
    public var rotated: Bool
    /// Worst axis; protrudes counts as tight.
    public var overall: Overall
    /// "36 in wide won't fit the 32 in opening (5 in short incl. clearance)".
    public var message: String
    public init(width: AxisVerdict, depth: AxisVerdict, height: AxisVerdict, rotated: Bool, overall: Overall, message: String) {
        self.width = width; self.depth = depth; self.height = height; self.rotated = rotated; self.overall = overall; self.message = message
    }
}

public struct FitClearance: Hashable, Codable, Sendable {
    public var width: Double, depth: Double, height: Double
    public init(width: Double = 0, depth: Double = 0, height: Double = 0) { self.width = width; self.depth = depth; self.height = height }
}

/// Per-item fit policy; defaults per template/category (HLD §9-12), user-editable per item.
public struct FitPolicy: Hashable, Codable, Sendable {
    /// Total inches added to the item on each axis.
    public var clearance: FitClearance
    /// May swap width/depth (furniture yes, front-facing appliances no).
    public var rotatable: Bool
    /// Appliances may stick out past counter depth → warning, not failure.
    public var depthMayProtrude: Bool
    public init(clearance: FitClearance = FitClearance(), rotatable: Bool = false, depthMayProtrude: Bool = false) {
        self.clearance = clearance; self.rotatable = rotatable; self.depthMayProtrude = depthMayProtrude
    }

    public static func `default`(templateKey: String?, category: Thing.Category) -> FitPolicy {
        switch templateKey {
        case "refrigerator": return FitPolicy(clearance: FitClearance(width: 1, depth: 1, height: 1), depthMayProtrude: true)
        case "range": return FitPolicy(depthMayProtrude: true)
        case "wall_oven", "cooktop": return FitPolicy()
        case "dishwasher": return FitPolicy(clearance: FitClearance(width: 0.25, depth: 0, height: 0.25))
        case "washer", "dryer": return FitPolicy(clearance: FitClearance(width: 1, depth: 4, height: 0), depthMayProtrude: true)
        case "tv": return FitPolicy(clearance: FitClearance(width: 2, depth: 0, height: 2))
        default: return category == .furniture ? FitPolicy(rotatable: true) : FitPolicy()
        }
    }
}

/// Pure fit check. LLD §10. Results are never stored.
public struct FitChecker: Sendable {
    public var tightTolerance: Double = 0.25
    public init(tightTolerance: Double = 0.25) { self.tightTolerance = tightTolerance }

    public func check(item: Dims3, into target: Dims3, policy: FitPolicy) -> FitResult {
        let c = policy.clearance
        var orientations: [(w: Double?, d: Double?, rotated: Bool)] = [(item.width, item.depth, false)]
        if policy.rotatable { orientations.append((item.depth, item.width, true)) }
        var best: (FitResult, Double)?
        for o in orientations {
            let vW = axis(need: o.w.map { $0 + c.width }, have: target.width)
            let vD = axis(need: o.d.map { $0 + c.depth }, have: target.depth, protrudeOK: policy.depthMayProtrude)
            let vH = axis(need: item.height.map { $0 + c.height }, have: target.height)
            let spares = [vW, vD, vH].compactMap(\.spare)
            let score = spares.min() ?? -.infinity
            let overall = Self.overall([vW, vD, vH])
            let msg = message(width: vW, depth: vD, height: vH, overall: overall,
                              itemW: o.w, itemD: o.d, itemH: item.height, target: target, rotated: o.rotated)
            let r = FitResult(width: vW, depth: vD, height: vH, rotated: o.rotated, overall: overall, message: msg)
            if best == nil || score > best!.1 { best = (r, score) }
        }
        return best!.0
    }

    /// Delivery-path check: longest dimension travels through the door; a ≤ door.width and b ≤ door.height
    /// (the swapped orientation is also tried). Diagonal tilting is out of scope for v1.
    public func passThrough(item: Dims3, door: Dims3) -> FitResult {
        let dims = item.known.sorted()
        guard dims.count == 3, let dw = door.width, let dh = door.height else {
            return FitResult(width: .unknown, depth: .unknown, height: .unknown, rotated: false, overall: .unknown,
                             message: "Add the item's width, depth and height and the door's width and height to check the path")
        }
        let a = dims[0], b = dims[1]
        let straight = (axis(need: a, have: dw), axis(need: b, have: dh))
        let swapped = (axis(need: b, have: dw), axis(need: a, have: dh))
        func score(_ p: (AxisVerdict, AxisVerdict)) -> Double { min(p.0.spare ?? -.infinity, p.1.spare ?? -.infinity) }
        let useSwap = score(swapped) > score(straight)
        let (vW, vH) = useSwap ? swapped : straight
        let overall = Self.overall([vW, vH])
        let doorText = "\(HomeLengthFormatter.formatInches(dw)) × \(HomeLengthFormatter.formatInches(dh)) door"
        let msg: String
        switch overall {
        case .fits: msg = "Fits through the \(doorText)"
        case .tight: msg = "Tight through the \(doorText)"
        case .noFit:
            let short = max(-(vW.spare ?? 0), -(vH.spare ?? 0))
            msg = "Won't fit through the \(doorText) (\(HomeLengthFormatter.formatInches(short)) short)"
        case .unknown: msg = "Can't check the path"
        }
        return FitResult(width: vW, depth: .unknown, height: vH, rotated: useSwap, overall: overall, message: msg)
    }

    func axis(need: Double?, have: Double?, protrudeOK: Bool = false) -> AxisVerdict {
        guard let need, let have else { return .unknown }
        let spare = have - need
        if spare >= tightTolerance { return .fits(spare: spare) }
        if spare >= 0 { return .tight(spare: spare) }
        return protrudeOK ? .protrudes(by: -spare) : .tooBig(by: -spare)
    }

    static func overall(_ vs: [AxisVerdict]) -> FitResult.Overall {
        let known = vs.filter { $0 != .unknown }
        guard !known.isEmpty else { return .unknown }
        switch known.map(\.severity).max()! {
        case 2: return .noFit
        case 1: return .tight
        default: return .fits
        }
    }

    private func message(width: AxisVerdict, depth: AxisVerdict, height: AxisVerdict, overall: FitResult.Overall,
                         itemW: Double?, itemD: Double?, itemH: Double?, target: Dims3, rotated: Bool) -> String {
        let f = { (v: Double) in HomeLengthFormatter.formatInches(v) }
        let axes: [(AxisVerdict, String, Double?, Double?, String)] = [
            (width, "wide", itemW, target.width, "opening"),
            (depth, "deep", itemD, target.depth, "depth"),
            (height, "tall", itemH, target.height, "height"),
        ]
        switch overall {
        case .unknown:
            return "Add dimensions to check the fit"
        case .noFit:
            let (_, adj, item, have, noun) = axes.first { if case .tooBig = $0.0 { return true }; return false }!
            guard case .tooBig(let by) = axes.first(where: { $0.1 == adj })!.0 else { return "" }
            return "\(f(item ?? 0)) \(adj) won't fit the \(f(have ?? 0)) \(noun) (\(f(by)) short incl. clearance)"
        case .tight:
            if let p = axes.first(where: { if case .protrudes = $0.0 { return true }; return false }), case .protrudes(let by) = p.0 {
                return "Sticks out \(f(by)) past the \(f(p.3 ?? 0)) depth"
            }
            let t = axes.first { if case .tight = $0.0 { return true }; return false }!
            return "Tight: \(f(t.0.spare ?? 0)) to spare \(t.1 == "wide" ? "in width" : t.1 == "deep" ? "in depth" : "in height")"
        case .fits:
            let spare = [width, depth, height].compactMap(\.spare).min() ?? 0
            return "Fits with \(f(spare)) to spare" + (rotated ? " (turned sideways)" : "")
        }
    }
}

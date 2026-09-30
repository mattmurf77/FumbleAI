import SwiftUI
import PhotosUI
import PlanKit
import HomeCore
#if canImport(UIKit)
import UIKit
#endif
#if canImport(VisionKit)
import HomeCapture   // DocumentScannerView (VNDocumentCameraViewController wrapper)
#endif

/// "Trace a photo" (HLD §4.3, LLD §6.9, FR-PLN-30..35):
/// 1. image from the photo picker (screenshots; no photo-library permission) or the document camera,
/// 2. two-point calibration with a loupe + known length (optional second pair; > 5 % disagreement warns),
/// 3. drag rectangles over the traced walls (model-space, 6 in grid), then Review. The image is stored as the
///    level's underlay (50 % opacity) and stays toggleable from the level menu.
@MainActor
struct TraceFlow: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable var model: OnboardingModel
    @State private var trace = TraceState()

    var body: some View {
        Group {
            switch trace.stage {
            case .pick: TraceSourcePicker(trace: trace)
            case .calibrate: TraceCalibrationView(trace: trace)
            case .rooms: TraceRoomsView(trace: trace) { finish() }
            }
        }
        .navigationTitle("Trace a photo")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func finish() {
        guard let image = trace.image, let t = trace.transform else { return }
        var transform = t
        transform.opacity = 0.5
        let attachment = AttachmentDraft(fileURL: image.fileURL, kind: .underlay, fileExt: "jpg", uti: "public.jpeg",
                                         widthPx: image.widthPx, heightPx: image.heightPx, caption: "Traced floor plan")
        let level = LevelDraft(name: "1st Floor", kind: .floor, sortOrder: 0, spaces: trace.rooms,
                               underlay: UnderlayDraft(image: attachment, transform: transform),
                               warnings: trace.stretched ? [.possiblyStretched] : [])
        model.seedExterior = true
        model.approxSqFt = nil
        model.useDraft(PlanDraft(levels: [level], source: .trace), path: .trace, env: env)
    }
}

// MARK: - State

@MainActor
@Observable
final class TraceState {
    enum Stage { case pick, calibrate, rooms }

    struct TraceImage {
        #if canImport(UIKit)
        var uiImage: UIImage
        #endif
        var fileURL: URL
        var widthPx: Int
        var heightPx: Int
        var size: Vec2 { Vec2(Double(widthPx), Double(heightPx)) }
    }

    var stage: Stage = .pick
    var image: TraceImage?
    var loadError: String?
    var transform: UnderlayTransform?
    var stretched = false
    var rooms: [SpaceDraft] = []

    static let minLongEdge = 800

    var isTooSmall: Bool { image.map { max($0.widthPx, $0.heightPx) < Self.minLongEdge } ?? false }

    #if canImport(UIKit)
    /// Normalizes orientation (renders at scale 1 so points == pixels) and writes a JPEG to Caches for the attachment.
    func load(_ data: Data) {
        guard let raw = UIImage(data: data) else { loadError = "That image couldn't be opened."; return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let pixelSize = CGSize(width: (raw.size.width * raw.scale).rounded(), height: (raw.size.height * raw.scale).rounded())
        let img = UIGraphicsImageRenderer(size: pixelSize, format: format).image { _ in raw.draw(in: CGRect(origin: .zero, size: pixelSize)) }
        guard let jpeg = img.jpegData(compressionQuality: 0.9) else { loadError = "That image couldn't be opened."; return }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Trace", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString.lowercased() + ".jpg")
        do { try jpeg.write(to: url, options: .atomic) } catch { loadError = "Couldn't save the image."; return }
        image = TraceImage(uiImage: img, fileURL: url, widthPx: Int(pixelSize.width), heightPx: Int(pixelSize.height))
        loadError = nil
        transform = nil
        rooms = []
        stage = .calibrate
    }
    #endif
}

/// Aspect-fit mapping between a view and image pixels.
struct TraceFit {
    let scale: Double
    let origin: CGPoint
    init(imageSize: Vec2, in size: CGSize) {
        let s = min(Double(size.width) / imageSize.x, Double(size.height) / imageSize.y)
        scale = s
        origin = CGPoint(x: (Double(size.width) - imageSize.x * s) / 2, y: (Double(size.height) - imageSize.y * s) / 2)
    }
    func pixel(_ p: CGPoint) -> Vec2 { Vec2((Double(p.x) - Double(origin.x)) / scale, (Double(p.y) - Double(origin.y)) / scale) }
    func view(_ p: Vec2) -> CGPoint { CGPoint(x: Double(origin.x) + p.x * scale, y: Double(origin.y) + p.y * scale) }
}

// MARK: - 1. Source

struct TraceSourcePicker: View {
    @Bindable var trace: TraceState
    @State private var item: PhotosPickerItem?
    @State private var showScanner = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 52)).foregroundStyle(Color.accentColor)
            Text("Start from a floor plan picture").font(.title2.weight(.bold))
            Text("A listing screenshot or a page from your closing papers works. For paper, the document scanner keeps it square.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            PhotosPicker(selection: $item, matching: .images) {
                Label("Choose a photo or screenshot", systemImage: "photo").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            #if canImport(VisionKit) && canImport(UIKit)
            if DocumentScannerView.isSupported {
                Button { showScanner = true } label: {
                    Label("Scan a paper plan", systemImage: "doc.viewfinder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.large)
            }
            #endif
            if let e = trace.loadError { Text(e).font(.footnote).foregroundStyle(.red) }
        }
        .padding(24)
        .onChange(of: item) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    #if canImport(UIKit)
                    trace.load(data)
                    #endif
                } else {
                    trace.loadError = "That image couldn't be opened."
                }
            }
        }
        #if canImport(VisionKit) && canImport(UIKit)
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScannerView(onFinish: { pages in
                showScanner = false
                if let first = pages.first { trace.load(first) }
            }, onCancel: { showScanner = false })
            .ignoresSafeArea()
        }
        #endif
    }
}

// MARK: - 2. Calibration

struct TraceCalibrationView: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable var trace: TraceState

    /// Tapped pixel points: A, B (required) and C, D (optional second pair).
    @State private var points: [Vec2] = []
    @State private var length1 = ""
    @State private var length2 = ""
    @State private var useSecond = false
    @State private var dragLocation: CGPoint?
    @State private var message: String?
    @State private var stretchedRatio: Double?

    private var needed: Int { useSecond ? 4 : 2 }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                if let img = trace.image {
                    let fit = TraceFit(imageSize: img.size, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        #if canImport(UIKit)
                        Image(uiImage: img.uiImage).resizable().scaledToFit().frame(width: geo.size.width, height: geo.size.height)
                        #endif
                        markers(fit)
                        if let loc = dragLocation { loupe(img, fit: fit, at: loc) }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { dragLocation = $0.location }
                        .onEnded { v in
                            dragLocation = nil
                            place(fit.pixel(v.location), in: img.size)
                        })
                }
            }
            .background(Color.black.opacity(0.04))
            controls
        }
    }

    private func place(_ p: Vec2, in size: Vec2) {
        guard p.x >= 0, p.y >= 0, p.x <= size.x, p.y <= size.y else { return }
        if points.count >= needed { points = [] }
        points.append(p)
        message = nil
    }

    @ViewBuilder
    private func markers(_ fit: TraceFit) -> some View {
        Canvas { ctx, _ in
            for pair in stride(from: 0, to: points.count, by: 2) {
                let a = fit.view(points[pair])
                if pair + 1 < points.count {
                    var line = Path(); line.move(to: a); line.addLine(to: fit.view(points[pair + 1]))
                    ctx.stroke(line, with: .color(pair == 0 ? .orange : .blue), lineWidth: 2.5)
                }
            }
            for (i, p) in points.enumerated() {
                let c = fit.view(p)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)), with: .color(i < 2 ? .orange : .blue))
                ctx.draw(Text(["A", "B", "C", "D"][i]).font(.caption.bold()), at: CGPoint(x: c.x + 12, y: c.y - 12))
            }
        }
        .allowsHitTesting(false)
    }

    /// Magnifier loupe above the finger (2.5×).
    @ViewBuilder
    private func loupe(_ img: TraceState.TraceImage, fit: TraceFit, at loc: CGPoint) -> some View {
        #if canImport(UIKit)
        let zoom = 2.5
        let size: CGFloat = 110
        let shownW = img.size.x * fit.scale, shownH = img.size.y * fit.scale
        Image(uiImage: img.uiImage)
            .resizable()
            .frame(width: shownW * zoom, height: shownH * zoom)
            .offset(x: size / 2 - (loc.x - fit.origin.x) * zoom, y: size / 2 - (loc.y - fit.origin.y) * zoom)
            .frame(width: size, height: size, alignment: .topLeading)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white, lineWidth: 3))
            .overlay(Image(systemName: "plus").foregroundStyle(.orange))
            .shadow(radius: 4)
            .position(x: loc.x, y: max(size / 2, loc.y - size))
            .allowsHitTesting(false)
        #endif
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(instruction).font(.subheadline.weight(.semibold))
            HStack {
                TextField("Length A–B, e.g. 13'2\"", text: $length1).textFieldStyle(.roundedBorder)
                if useSecond { TextField("Length C–D", text: $length2).textFieldStyle(.roundedBorder) }
            }
            Toggle("Add a second measurement (recommended)", isOn: $useSecond)
                .font(.footnote)
                .onChange(of: useSecond) { _, on in if !on && points.count > 2 { points = Array(points.prefix(2)) } }
            if trace.isTooSmall {
                Label("This image is too small to trace accurately", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
            if let m = message { Text(m).font(.footnote).foregroundStyle(.red) }
            if let r = stretchedRatio {
                VStack(alignment: .leading, spacing: 6) {
                    Label("This image may be stretched. Try the document scanner.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                    Text("The two measurements differ by \(Int((r * 100).rounded()))%.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Use anyway") { useAveraged() }.buttonStyle(.bordered)
                        Button("Choose another image") { trace.stage = .pick; trace.image = nil }.buttonStyle(.bordered)
                    }
                }
            }
            Button(action: calibrate) { Text("Set scale").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(points.count < needed)
        }
        .padding(16)
        .background(.bar)
    }

    private var instruction: String {
        switch points.count {
        case 0: return "Tap one end of a wall you know the length of (A)."
        case 1: return "Now tap the other end (B)."
        case 2 where useSecond: return "Tap one end of a wall going the other way (C)."
        case 3: return "Tap its other end (D)."
        default: return "Enter the real length\(useSecond ? "s" : "") and set the scale."
        }
    }

    private func parse(_ s: String) -> Double? {
        guard let v = HomeLengthFormatter.parse(s), v > 0 else { return nil }
        return v
    }

    private func calibrate() {
        guard let img = trace.image else { return }
        guard let l1 = parse(length1) else { message = "Enter a length greater than 0"; return }
        var second: (Vec2, Vec2, Double)?
        if useSecond {
            guard let l2 = parse(length2) else { message = "Enter a length greater than 0"; return }
            second = (points[2], points[3], l2)
        }
        switch env.photoTrace.calibrate(a: points[0], b: points[1], lengthIn: l1, second: second, imageSize: img.size, contentCenter: .zero) {
        case .success(let t):
            trace.transform = t
            trace.stretched = false
            trace.stage = .rooms
        case .failure(.possiblyStretched(let ratio)):
            stretchedRatio = ratio
        case .failure(.invalidInput):
            message = "Tap two points farther apart and enter a length greater than 0."
        }
    }

    /// Both pairs, averaged scale (§6.9 step 4), after the user accepted the stretch warning.
    private func useAveraged() {
        guard let img = trace.image, let l1 = parse(length1), let l2 = parse(length2), points.count == 4,
              case .success(var t) = env.photoTrace.calibrate(a: points[0], b: points[1], lengthIn: l1, second: nil,
                                                             imageSize: img.size, contentCenter: .zero) else { return }
        let s2 = l2 / max(points[2].distance(to: points[3]), 1)
        t.inchesPerPixel = (t.inchesPerPixel + s2) / 2
        t.originIn = .zero
        t.originIn = Vec2.zero - t.toModel(pixel: img.size / 2)   // image center on the content center
        trace.transform = t
        trace.stretched = true
        stretchedRatio = nil
        trace.stage = .rooms
    }
}

// MARK: - 3. Rooms

struct TraceRoomsView: View {
    @Bindable var trace: TraceState
    let onContinue: () -> Void

    @State private var type: SpaceType = .room
    @State private var dragStart: Vec2?
    @State private var dragEnd: Vec2?
    @State private var message: String?

    static let types: [SpaceType] = [.living, .kitchen, .dining, .bedroom, .bathroom, .halfBath, .hall, .stairs, .closet, .laundry, .garage, .office, .room]
    static let grid = 6.0

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                if let img = trace.image, let t = trace.transform {
                    let fit = TraceFit(imageSize: img.size, in: geo.size)
                    ZStack {
                        #if canImport(UIKit)
                        Image(uiImage: img.uiImage).resizable().scaledToFit().opacity(0.5)
                            .frame(width: geo.size.width, height: geo.size.height)
                        #endif
                        Canvas { ctx, _ in
                            func quad(_ poly: [Vec2]) -> Path {
                                var p = Path(); p.addLines(poly.map { fit.view(t.toPixel(model: $0)) }); p.closeSubpath(); return p
                            }
                            for r in trace.rooms {
                                let path = quad(r.polygon.vertices)
                                ctx.fill(path, with: .color(DraftPlanPreview.fill(for: r).opacity(0.9)))
                                ctx.stroke(path, with: .color(.primary), lineWidth: 1.5)
                                ctx.draw(Text(r.name).font(.caption.weight(.medium)), at: fit.view(t.toPixel(model: r.polygon.centroid)))
                            }
                            if let a = dragStart, let b = dragEnd {
                                ctx.stroke(quad(Self.rect(a, b).corners), with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                            }
                        }
                        .allowsHitTesting(false)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 4)
                        .onChanged { v in
                            let a = Self.snap(t.toModel(pixel: fit.pixel(v.startLocation)))
                            dragStart = a
                            dragEnd = Self.snap(t.toModel(pixel: fit.pixel(v.location)))
                        }
                        .onEnded { _ in addRoom() })
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Drag over each room's walls to trace it.").font(.subheadline.weight(.semibold))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(Self.types, id: \.self) { t in
                            Button(t.displayName) { type = t }
                                .buttonStyle(.bordered)
                                .tint(type == t ? .accentColor : .secondary)
                        }
                    }
                }
                if let m = message { Text(m).font(.footnote).foregroundStyle(.orange) }
                HStack {
                    Button("Undo") { if !trace.rooms.isEmpty { trace.rooms.removeLast() } }
                        .disabled(trace.rooms.isEmpty)
                    Spacer()
                    Text("\(trace.rooms.count) room\(trace.rooms.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                }
                Button(action: onContinue) {
                    Text(trace.rooms.isEmpty ? "Continue without rooms" : "Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
            .padding(16)
            .background(.bar)
        }
    }

    static func snap(_ v: Vec2) -> Vec2 { Vec2(Geometry.snap(v.x, to: grid), Geometry.snap(v.y, to: grid)) }
    static func rect(_ a: Vec2, _ b: Vec2) -> PlanKit.Rect {
        PlanKit.Rect(minX: min(a.x, b.x), minY: min(a.y, b.y), maxX: max(a.x, b.x), maxY: max(a.y, b.y))
    }

    private func addRoom() {
        defer { dragStart = nil; dragEnd = nil }
        guard let a = dragStart, let b = dragEnd else { return }
        let r = Self.rect(a, b)
        guard r.width >= 24, r.height >= 24, let poly = try? PlanKit.Polygon(r.corners) else {
            message = "That's too small for a room."; return
        }
        if trace.rooms.contains(where: { Clip.intersectionArea($0.polygon, poly) > Tolerance.maxInteriorOverlap }) {
            message = "Rooms can't overlap. Trace up to the shared wall."; return
        }
        let base = type.displayName
        let taken = Set(trace.rooms.map(\.name))
        var name = base, n = 2
        while taken.contains(name) { name = "\(base) \(n)"; n += 1 }
        trace.rooms.append(SpaceDraft(name: name, spaceType: type, polygon: poly, source: .trace))
        message = nil
    }
}

#Preview("Trace – pick") {
    NavigationStack { TraceFlow(model: OnboardingModel()) }
        .environment(AppEnvironment.preview(sample: false))
}

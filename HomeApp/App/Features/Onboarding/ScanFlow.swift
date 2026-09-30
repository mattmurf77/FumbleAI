import SwiftUI
import HomeCore
#if canImport(RoomPlan)
import UIKit
import RoomPlan
import ARKit
import AVFoundation
#endif

/// FR-PLN-03: Scan is offered only on LiDAR devices.
enum ScanCapability {
    static var isSupported: Bool {
        #if canImport(RoomPlan) && !targetEnvironment(simulator)
        return RoomCaptureSession.isSupported && ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        #else
        return false
        #endif
    }
}

/// Scan (RoomPlan, HLD §4.1, FR-PLN-36..39): one `RoomCaptureView` whose `ARSession` is reused across the rooms of a
/// floor (iOS 17 multi-room); "Finish floor" merges the rooms with `StructureBuilder`, encodes the
/// `CapturedStructure` JSON and hands it to `RoomPlanImporting` → Review.
struct ScanFlow: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        #if canImport(RoomPlan)
        if ScanCapability.isSupported {
            RoomScanView(model: model)
        } else {
            unsupported
        }
        #else
        unsupported
        #endif
    }

    private var unsupported: some View {
        ContentUnavailableView {
            Label("Scanning needs a LiDAR iPhone", systemImage: "camera.metering.unknown")
        } description: {
            Text("Build with blocks or Rough it in make the same editable plan.")
        } actions: {
            Button("Build with blocks") { model.routes.removeLast(); model.routes.append(.blocks) }
            Button("Rough it in") { model.routes.removeLast(); model.routes.append(.rough) }
        }
    }
}

#if canImport(RoomPlan)

/// Collects processed rooms from the capture view.
final class ScanCaptureDelegate: NSObject, RoomCaptureViewDelegate {
    var onRoom: ((CapturedRoom?, Error?) -> Void)?

    override init() { super.init() }
    // RoomCaptureViewDelegate inherits NSCoding; the delegate is never archived.
    init?(coder: NSCoder) { super.init() }
    func encode(with coder: NSCoder) {}

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool { true }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        onRoom?(error == nil ? processedResult : nil, error)
    }
}

/// Owns the capture view and the rooms scanned so far (kept if the session is interrupted).
@MainActor
@Observable
final class ScanSession {
    let captureView: RoomCaptureView
    private let delegate = ScanCaptureDelegate()
    var rooms: [CapturedRoom] = []
    var isCapturing = false
    var isProcessing = false
    var failures = 0
    var message: String?

    init() {
        captureView = RoomCaptureView(frame: .zero)
        captureView.delegate = delegate
        delegate.onRoom = { [weak self] room, error in
            Task { @MainActor in self?.received(room, error) }
        }
    }

    private func received(_ room: CapturedRoom?, _ error: Error?) {
        isProcessing = false
        if let room {
            rooms.append(room)
            message = nil
        } else {
            failures += 1
            message = "Scanning paused — move slowly and point at walls"
        }
    }

    func startRoom() {
        message = nil
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        isCapturing = true
    }

    /// Ends this room but keeps the ARSession running for the next one (iOS 17).
    func finishRoom() {
        captureView.captureSession.stop(pauseARSession: false)
        isCapturing = false
        isProcessing = true
    }

    func stopAll() {
        if isCapturing { captureView.captureSession.stop() }
        isCapturing = false
    }

    /// Merges the floor's rooms (`StructureBuilder`, §6.12) and returns the `CapturedStructure` JSON.
    func structureJSON() async throws -> Data {
        let structure = try await StructureBuilder(options: []).capturedStructure(from: rooms)
        return try JSONEncoder().encode(structure)
    }
}

struct RoomCaptureContainer: UIViewRepresentable {
    let view: RoomCaptureView
    func makeUIView(context: Context) -> RoomCaptureView { view }
    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}

struct RoomScanView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openURL) private var openURL
    @Bindable var model: OnboardingModel
    @State private var session: ScanSession?
    @State private var cameraDenied = false
    @State private var building = false
    @State private var failure: String?

    var body: some View {
        Group {
            if cameraDenied {
                ContentUnavailableView {
                    Label("Camera access is off", systemImage: "camera.fill")
                } description: {
                    Text("Turn on camera access in Settings to scan rooms, or pick another way to create your plan.")
                } actions: {
                    Button("Open Settings") { if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) } }
                    Button("Try another way") { model.routes.removeLast() }
                }
            } else if let session {
                scanning(session)
            } else {
                intro
            }
        }
        .navigationTitle("Scan")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { session?.stopAll() }
    }

    private var intro: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.viewfinder").font(.system(size: 56)).foregroundStyle(Color.accentColor)
            Text("Scan one room at a time").font(.title2.weight(.bold))
            Text("Stand in a doorway, then slowly walk the room pointing at the walls. When you finish a room, walk to the next one. Tap Finish floor when this floor is done.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let failure { Text(failure).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center) }
            Button { Task { await start() } } label: { Text("Start scanning").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(24)
    }

    @ViewBuilder
    private func scanning(_ s: ScanSession) -> some View {
        ZStack(alignment: .bottom) {
            RoomCaptureContainer(view: s.captureView).ignoresSafeArea()
            VStack(spacing: 10) {
                if let msg = s.message {
                    Text(msg).font(.subheadline.weight(.semibold)).padding(10)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Text("\(s.rooms.count) room\(s.rooms.count == 1 ? "" : "s") scanned on this floor")
                    .font(.footnote).foregroundStyle(.secondary)
                if building {
                    ProgressView("Putting your floor together…").padding()
                } else if s.isCapturing {
                    Button { s.finishRoom() } label: { Text("Done with this room").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                } else if s.isProcessing {
                    ProgressView("Processing room…")
                } else {
                    if s.failures >= 3 && !s.rooms.isEmpty {
                        Button("Finish with what we have") { Task { await finishFloor(s) } }
                            .buttonStyle(.borderedProminent)
                        Button("Try another way") { s.stopAll(); model.routes.removeLast() }
                    } else {
                        HStack {
                            Button { s.startRoom() } label: { Text(s.rooms.isEmpty ? "Scan a room" : "Scan next room").frame(maxWidth: .infinity) }
                                .buttonStyle(.bordered).controlSize(.large)
                            Button { Task { await finishFloor(s) } } label: { Text("Finish floor").frame(maxWidth: .infinity) }
                                .buttonStyle(.borderedProminent).controlSize(.large)
                                .disabled(s.rooms.isEmpty)
                        }
                    }
                }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .padding()
        }
        .toolbar(.hidden, for: .tabBar)
    }

    private func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { cameraDenied = true; return }
        default:
            cameraDenied = true; return
        }
        let s = ScanSession()
        session = s
        s.startRoom()
    }

    private func finishFloor(_ s: ScanSession) async {
        s.stopAll()
        building = true
        defer { building = false }
        do {
            let data = try await s.structureJSON()
            try model.importScan(data, env: env)
        } catch OnboardingModel.ScanImportFailure.noRooms {
            failure = "We couldn't find any rooms. Try again with more light, or use Build with blocks."
            session = nil
        } catch {
            failure = "We couldn't put the rooms together. Try again, or use Build with blocks."
            session = nil
        }
    }
}
#endif

#Preview("Scan – unsupported") {
    NavigationStack { ScanFlow(model: OnboardingModel()) }
        .environment(AppEnvironment.preview(sample: false))
}

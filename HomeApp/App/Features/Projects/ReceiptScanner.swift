import SwiftUI
import PhotosUI
import HomeCore
import HomeCoreTesting
#if canImport(UIKit)
import UIKit
#endif
#if canImport(VisionKit)
import VisionKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Result of a receipt scan: the pages saved as one PDF (to attach with kind `receipt`) plus the parsed suggestions.
/// Parsing / OCR live in HomeCapture behind `env.receipts` (`ReceiptReading`, LLD §15); this is only the UI hook.
struct ScannedReceipt: Identifiable, Equatable {
    let id = UUID()
    var pdfURL: URL
    var pageCount: Int
    /// nil when OCR failed ("Couldn't read this receipt…"): the PDF is still attachable.
    var guess: ReceiptGuess?
    var capturedAt: Date

    static let maxBytes = 25 * 1024 * 1024

    var attachmentDraft: AttachmentDraft {
        AttachmentDraft(fileURL: pdfURL, kind: .receipt, fileExt: "pdf", uti: "com.adobe.pdf",
                        caption: guess?.vendor, ocrText: guess?.fullText, capturedAt: capturedAt)
    }
}

/// "Scan receipt" button (FR-PRJ-22): document camera (VNDocumentCameraViewController) when available, otherwise
/// (simulator, camera denied) a photo picker. Calls `onScanned` after OCR; nothing is saved here.
struct ReceiptScanButton: View {
    @Environment(AppEnvironment.self) private var env
    var title = "Scan receipt"
    var systemImage = "doc.text.viewfinder"
    let onScanned: (ScannedReceipt) -> Void

    @State private var showCamera = false
    @State private var showPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var cameraDenied = false
    @State private var working = false
    @State private var errorText: String?

    var body: some View {
        Button {
            start()
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                if working { Spacer(); ProgressView() }
            }
        }
        .disabled(working)
        #if canImport(VisionKit) && os(iOS)
        .fullScreenCover(isPresented: $showCamera) {
            DocumentCameraView { images in
                showCamera = false
                Task { await process(images.compactMap { $0.jpegData(compressionQuality: 0.8) }) }
            } onCancel: {
                showCamera = false
            }
            .ignoresSafeArea()
        }
        #endif
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 5, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var datas: [Data] = []
                for item in items { if let d = try? await item.loadTransferable(type: Data.self) { datas.append(d) } }
                photoItems = []
                await process(datas)
            }
        }
        .alert("Camera access is off", isPresented: $cameraDenied) {
            Button("Choose a photo") { showPhotos = true }
            #if canImport(UIKit)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            #endif
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow camera access for Home in Settings to scan receipts, or pick a photo of the receipt instead.")
        }
        .alert("Receipt", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    private func start() {
        #if canImport(VisionKit) && os(iOS)
        #if canImport(AVFoundation)
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .denied || status == .restricted { cameraDenied = true; return }
        #endif
        if VNDocumentCameraViewController.isSupported { showCamera = true; return }
        #endif
        showPhotos = true
    }

    @MainActor
    private func process(_ images: [Data]) async {
        guard !images.isEmpty else { return }
        working = true
        defer { working = false }
        guard let pdf = ReceiptPDF.write(images: images) else {
            errorText = "Couldn’t save the scan. Try again."
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: pdf.path)[.size] as? Int) ?? 0
        if size > ScannedReceipt.maxBytes {
            try? FileManager.default.removeItem(at: pdf)
            errorText = "This file is too large (max 25 MB)."
            return
        }
        var guess: ReceiptGuess?
        do { guess = try await env.receipts.read(images: images) } catch {
            errorText = "Couldn’t read this receipt. You can still attach it and type the amount."
        }
        onScanned(ScannedReceipt(pdfURL: pdf, pageCount: images.count, guess: guess, capturedAt: env.clock.now))
    }
}

/// Writes scanned pages into one PDF in the temporary directory (the attachment store copies it).
enum ReceiptPDF {
    static func write(images: [Data]) -> URL? {
        #if canImport(UIKit)
        let pages = images.compactMap { UIImage(data: $0) }
        guard !pages.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-\(UUID().uuidString).pdf")
        let pageWidth: CGFloat = 612   // US Letter width in points
        let first = pages[0]
        let firstHeight = first.size.width > 0 ? pageWidth * first.size.height / first.size.width : 792
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageWidth, height: firstHeight))
        do {
            try renderer.writePDF(to: url) { ctx in
                for image in pages {
                    let h = image.size.width > 0 ? pageWidth * image.size.height / image.size.width : 792
                    let bounds = CGRect(x: 0, y: 0, width: pageWidth, height: h)
                    ctx.beginPage(withBounds: bounds, pageInfo: [:])
                    image.draw(in: bounds)
                }
            }
            return url
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}

#if canImport(VisionKit) && os(iOS)
/// VNDocumentCameraViewController wrapper returning the scanned pages.
struct DocumentCameraView: UIViewControllerRepresentable {
    let onFinish: ([UIImage]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: ([UIImage]) -> Void
        let onCancel: () -> Void
        init(onFinish: @escaping ([UIImage]) -> Void, onCancel: @escaping () -> Void) {
            self.onFinish = onFinish; self.onCancel = onCancel
        }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            onFinish((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { onCancel() }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { onCancel() }
    }
}
#endif

/// Shows parsed receipt values, each marked "From receipt – check" (FR-PRJ-22, AC-PRJ-6). Nothing is saved until
/// the user picks an action.
struct ReceiptReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let receipt: ScannedReceipt
    let currency: String
    /// Attach the PDF to the project only.
    var onAttach: () -> Void
    /// Add a line item prefilled from the receipt (the editor lets the user check the values).
    var onAddLineItem: (() -> Void)?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Pages", value: "\(receipt.pageCount)")
                    if let g = receipt.guess {
                        suggestion("Total", g.total.map { $0.formatted() })
                        suggestion("Date", g.date.map { ScheduleFormat.longDay($0) })
                        suggestion("Vendor", g.vendor)
                    } else {
                        Text("Couldn’t read this receipt. You can still attach it and type the amount.")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Values read from the receipt are suggestions. Check them before saving.")
                }
                Section {
                    if let onAddLineItem {
                        Button { onAddLineItem(); dismiss() } label: { Label("Add as a line item…", systemImage: "plus.circle") }
                    }
                    Button { onAttach(); dismiss() } label: { Label("Attach to project", systemImage: "paperclip") }
                }
            }
            .navigationTitle("Scanned receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Discard") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func suggestion(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(label, value: value ?? "—")
            if value != nil {
                Label("From receipt – check", systemImage: "doc.text.viewfinder").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

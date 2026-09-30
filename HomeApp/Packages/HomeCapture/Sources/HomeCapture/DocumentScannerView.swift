#if canImport(VisionKit) && canImport(UIKit) && canImport(SwiftUI) && os(iOS)
import SwiftUI
import UIKit
import VisionKit

/// SwiftUI wrapper for `VNDocumentCameraViewController` (perspective-corrected pages). Used by "Trace a photo"
/// (FR-PLN-30) and receipts (LLD §15 step 1). Pages are returned as JPEG data (quality 0.85), in order.
/// Check `DocumentScannerView.isSupported` before presenting (false on the simulator).
public struct DocumentScannerView: UIViewControllerRepresentable {
    public static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    public var onFinish: ([Data]) -> Void
    public var onCancel: () -> Void

    public init(onFinish: @escaping ([Data]) -> Void, onCancel: @escaping () -> Void) {
        self.onFinish = onFinish; self.onCancel = onCancel
    }

    public func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    public func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScannerView
        init(_ parent: DocumentScannerView) { self.parent = parent }

        public func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            var pages: [Data] = []
            for i in 0..<scan.pageCount {
                if let d = scan.imageOfPage(at: i).jpegData(compressionQuality: 0.85) { pages.append(d) }
            }
            parent.onFinish(pages)
        }

        public func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { parent.onCancel() }

        public func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.onCancel()
        }
    }
}
#endif

import SwiftUI
import PhotosUI
import HomeCore
import HomeCapture   // LabelTextRecognizer (Vision OCR), DocumentScannerView (VNDocumentCameraViewController)
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Result of "Scan label": what `LabelReader` read from a photo of an appliance's model / serial sticker, plus the
/// photo (JPEG) so it can be kept with the item. Nothing is saved here.
struct ScannedLabel: Equatable {
    var guess: LabelGuess
    /// OCR rows, top to bottom (kept as the photo's OCR text).
    var lines: [String]
    /// First page as JPEG; nil when it couldn't be converted.
    var photo: Data?
}

extension View {
    /// "Scan label": when `isPresented` turns true, asks for a photo (document camera or photo library; library
    /// only where there's no camera), reads it with Vision and calls `onScanned`. `working` is true while reading.
    func labelScanner(isPresented: Binding<Bool>, working: Binding<Bool>, today: LocalDate,
                      onScanned: @escaping (ScannedLabel) -> Void, onFailed: @escaping (String) -> Void) -> some View {
        modifier(LabelScannerModifier(isPresented: isPresented, working: working, today: today, onScanned: onScanned, onFailed: onFailed))
    }
}

@MainActor
struct LabelScannerModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var working: Bool
    let today: LocalDate
    let onScanned: (ScannedLabel) -> Void
    let onFailed: (String) -> Void

    @State private var showChoice = false
    @State private var showCamera = false
    @State private var showPhotos = false
    @State private var photoItem: PhotosPickerItem?
    @State private var cameraDenied = false

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, requested in
                guard requested else { return }
                isPresented = false
                start()
            }
            .confirmationDialog("Scan a label", isPresented: $showChoice, titleVisibility: .visible) {
                Button("Take a photo") { openCamera() }
                Button("Choose a photo") { showPhotos = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Photograph the sticker with the model and serial number. It’s usually inside the door, on the back or on the side.")
            }
            #if canImport(VisionKit) && canImport(UIKit) && os(iOS)
            .fullScreenCover(isPresented: $showCamera) {
                DocumentScannerView(onFinish: { pages in
                    showCamera = false
                    Task { await process(pages) }
                }, onCancel: {
                    showCamera = false
                })
                .ignoresSafeArea()
            }
            #endif
            .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    let data = try? await item.loadTransferable(type: Data.self)
                    photoItem = nil
                    if let data { await process([data]) } else { onFailed("That photo couldn’t be opened.") }
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
                Text("Allow camera access for Home in Settings to scan labels, or pick a photo of the label instead.")
            }
    }

    private var cameraAvailable: Bool {
        #if canImport(VisionKit) && canImport(UIKit) && os(iOS)
        return DocumentScannerView.isSupported
        #else
        return false
        #endif
    }

    private func start() {
        if cameraAvailable { showChoice = true } else { showPhotos = true }
    }

    private func openCamera() {
        #if canImport(AVFoundation) && os(iOS)
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .denied || status == .restricted { cameraDenied = true; return }
        #endif
        showCamera = true
    }

    private func process(_ images: [Data]) async {
        guard !images.isEmpty else { return }
        working = true
        defer { working = false }
        do {
            let rows = try await LabelTextRecognizer.rows(images: images)
            let guess = LabelReader.read(lines: rows, today: today)
            onScanned(ScannedLabel(guess: guess, lines: rows, photo: Self.jpeg(images[0])))
        } catch {
            onFailed("Couldn’t read that photo. Try again closer to the label, or type the details in.")
        }
    }

    /// Photo-library images can be HEIC; attachments are stored as JPEG.
    private static func jpeg(_ data: Data) -> Data? {
        #if canImport(UIKit)
        return UIImage(data: data)?.jpegData(compressionQuality: 0.8)
        #else
        return nil
        #endif
    }
}

import UIKit
import SwiftUI
import UniformTypeIdentifiers
import HomeCore

/// Share sheet → "Home Blueprint": previews the to-dos found in the shared text (a Notes list, a message, a web
/// page's selected text) and saves it for the app, which opens it in Quick add for review next time it's opened.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(model: model,
                                                           onCancel: { [weak self] in self?.finish(cancelled: true) },
                                                           onSave: { [weak self] in self?.save() }))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        Task { await loadSharedText() }
    }

    private func loadSharedText() async {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        var pieces: [String] = []
        for item in items {
            if let text = item.attributedContentText?.string, !text.isEmpty { pieces.append(text) }
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    pieces.append(text)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                          let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    pieces.append(url.absoluteString)
                }
            }
        }
        // Notes often sends the same text as both content text and an attachment.
        var seen = Set<String>()
        let text = pieces.filter { seen.insert($0.trimmingCharacters(in: .whitespacesAndNewlines)).inserted }.joined(separator: "\n")
        await MainActor.run { model.setText(text) }
    }

    private func save() {
        if SharedCaptureInbox.append(model.text) {
            model.saved = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.6))
                self.finish(cancelled: false)
            }
        } else {
            model.errorText = "Couldn’t save the list. Copy it instead and use Paste a list in the To-Dos tab."
        }
    }

    private func finish(cancelled: Bool) {
        if cancelled {
            extensionContext?.cancelRequest(withError: NSError(domain: "HomeShare", code: NSUserCancelledError))
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
}

@MainActor
@Observable
final class ShareModel {
    private(set) var text = ""
    private(set) var items: [String] = []
    private(set) var loaded = false
    var saved = false
    var errorText: String?

    func setText(_ t: String) {
        text = t
        items = ListCapture.items(from: t)
        loaded = true
    }
}

struct ShareView: View {
    let model: ShareModel
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if model.saved {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
                        Text("Saved").font(.title2.bold())
                        Text("Open Home Blueprint to review and add them.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !model.loaded {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.items.isEmpty {
                    ContentUnavailableView("No to-dos found", systemImage: "text.badge.xmark",
                                           description: Text("Share a list or some text, like a checklist from Notes."))
                } else {
                    List {
                        Section {
                            ForEach(Array(model.items.enumerated()), id: \.offset) { _, item in
                                Label(item, systemImage: "circle")
                            }
                        } header: {
                            Text(model.items.count == 1 ? "1 to-do" : "\(model.items.count) to-dos")
                        } footer: {
                            Text("You’ll review them, and choose when and where, in Home Blueprint.")
                        }
                        if let err = model.errorText {
                            Section { Text(err).foregroundStyle(.red) }
                        }
                    }
                }
            }
            .navigationTitle("Add to-dos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !model.saved {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save", action: onSave).disabled(model.items.isEmpty)
                    }
                }
            }
        }
    }
}

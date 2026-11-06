import UIKit
import SwiftUI
import UniformTypeIdentifiers
import HomeCore

/// Share sheet → "Home Blueprint". Text (a Notes list, a message, an email you selected) is saved as to-dos — previewed
/// here, reviewed in Quick add — or as a note / receipt to file. Photos, screenshots and PDFs (a receipt or invoice
/// attached to an email, Mail's Print → Share) are saved as a receipt or a document. Everything waits in
/// `SharedCaptureInbox` until the app is next opened.
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
        Task { await loadShared() }
    }

    private func loadShared() async {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        // Detect a spreadsheet BEFORE considering attributed text, URLs, thumbnails or task-list alternatives.
        var spreadsheet: SharedSpreadsheetProvider.SpreadsheetResult?
        var otherFile = false
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            if let found = await SharedSpreadsheetProvider.read(provider) {
                if spreadsheet != nil {
                    model.setSpreadsheet(.problem("Share one spreadsheet at a time. " + SharedInbox.Spreadsheet.openInFiles))
                    return
                }
                spreadsheet = found
            } else if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
                        || provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                otherFile = true
            }
        }
        if let spreadsheet {
            model.setSpreadsheet(otherFile ? .problem("Share the spreadsheet separately from photos or PDFs.") : spreadsheet)
            return
        }
        var pieces: [String] = []
        var files: [ReceivedFile] = []
        var problems: [String] = []
        var extraFiles = 0
        var imageNumber = 0
        for item in items {
            if let text = item.attributedContentText?.string, !text.isEmpty { pieces.append(text) }
            for provider in item.attachments ?? [] {
                let isPDF = provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
                let isImage = !isPDF && provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                if isPDF || isImage {
                    guard files.count < SharedInbox.maxFiles else { extraFiles += 1; continue }
                    imageNumber += isImage ? 1 : 0
                    let outcome: ShareFileLoader.Outcome
                    if isPDF {
                        outcome = await ShareFileLoader.loadPDF(provider)
                    } else {
                        outcome = await ShareFileLoader.loadImage(provider, number: imageNumber)
                    }
                    switch outcome {
                    case .file(let f):
                        let total = files.reduce(0) { $0 + $1.data.count } + f.data.count
                        if total > SharedInbox.maxTotalBytes {
                            problems.append("“\(f.file.name)” was left out — that’s a lot at once. Share it on its own.")
                        } else {
                            files.append(f)
                        }
                    case .problem(let message): problems.append(message)
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    pieces.append(text)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                          let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL,
                          !url.isFileURL {
                    pieces.append(url.absoluteString)
                }
            }
        }
        if extraFiles > 0 {
            problems.append("Only the first \(SharedInbox.maxFiles) files are saved — share the rest separately.")
        }
        // Notes often sends the same text as both content text and an attachment.
        var seen = Set<String>()
        let text = pieces.filter { seen.insert($0.trimmingCharacters(in: .whitespacesAndNewlines)).inserted }.joined(separator: "\n")
        let received = files
        let notes = problems
        await MainActor.run { model.setContent(text: text, files: received, problems: notes) }
    }

    private func save() {
        let ok: Bool
        if let sheet = model.spreadsheet {
            ok = SharedCaptureInbox.saveSpreadsheet(sheet)
        } else if model.kind == .todos && model.files.isEmpty {
            ok = SharedCaptureInbox.append(model.text)
        } else {
            let payloads = model.files.map { SharedCaptureInbox.Payload(file: $0.file, data: $0.data) }
            ok = SharedCaptureInbox.append(kind: model.kind, text: model.text, payloads: payloads)
        }
        if ok {
            model.saved = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.6))
                self.finish(cancelled: false)
            }
        } else if model.spreadsheet != nil {
            model.errorText = "Couldn’t hand off the original file. " + SharedInbox.Spreadsheet.openInFiles
        } else if model.files.isEmpty {
            model.errorText = "Couldn’t save it. Copy the text instead and use Paste a list in the To-Dos tab."
        } else {
            model.errorText = "Couldn’t save the files. Try sharing fewer at once, or save them to Files first."
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
    private(set) var spreadsheet: SharedInbox.Spreadsheet?
    private(set) var text = ""
    /// To-dos found in the text.
    private(set) var items: [String] = []
    private(set) var files: [ReceivedFile] = []
    /// Files that couldn't be taken (too large, unreadable).
    private(set) var problems: [String] = []
    private(set) var loaded = false
    var kind: SharedInbox.Kind = .todos
    var saved = false
    var errorText: String?

    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Files: receipt or document. Text only: to-dos, a note (e.g. a contractor's reply) or a receipt.
    var kindChoices: [SharedInbox.Kind] { files.isEmpty ? [.todos, .note, .receipt] : [.receipt, .document] }

    var canSave: Bool {
        guard loaded, !saved else { return false }
        if spreadsheet != nil { return true }
        if kind == .todos { return files.isEmpty && !items.isEmpty }
        return !files.isEmpty || hasText
    }

    func setSpreadsheet(_ result: SharedSpreadsheetProvider.SpreadsheetResult) {
        switch result {
        case .file(let original): spreadsheet = original
        case .problem(let message): problems = [message]
        }
        loaded = true
    }

    func setContent(text t: String, files f: [ReceivedFile], problems p: [String]) {
        if f.isEmpty, SharedInbox.Spreadsheet.isProjectTablePreview(t) {
            setSpreadsheet(.problem("Only a text preview was shared. " + SharedInbox.Spreadsheet.openInFiles))
            return
        }
        text = t
        items = ListCapture.items(from: t)
        files = f
        problems = p
        // A short list reads as to-dos; longer prose (an email, a message) as a note.
        if !f.isEmpty { kind = .receipt }
        else if !items.isEmpty && (items.count > 1 || t.count < 120) { kind = .todos }
        else { kind = .note }
        loaded = true
    }
}

struct ShareView: View {
    @Bindable var model: ShareModel
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if model.saved {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
                        Text("Saved").font(.title2.bold())
                        Text(model.spreadsheet != nil ? "Open Home Blueprint to review the spreadsheet."
                             : model.kind == .todos ? "Open Home Blueprint to review and add them." : "Open Home Blueprint to file it.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !model.loaded {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let spreadsheet = model.spreadsheet {
                    List {
                        Section {
                            Label(spreadsheet.name, systemImage: "tablecells")
                            Text(SharedInbox.sizeText(spreadsheet.bytes.count)).foregroundStyle(.secondary)
                        } footer: { Text("Open Home Blueprint to match columns and choose which projects to import.") }
                    }
                } else if model.files.isEmpty && !model.hasText {
                    ContentUnavailableView {
                        Label("Nothing to save", systemImage: "tray")
                    } description: {
                        Text(model.problems.first
                             ?? "Share a list, an email or message, a receipt photo or a PDF to save it in Home Blueprint.")
                    }
                } else {
                    content
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !model.saved {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(model.spreadsheet == nil ? "Save" : "Send for review", action: onSave).disabled(!model.canSave)
                    }
                }
            }
        }
    }

    private var title: String {
        if !model.loaded || model.saved { return "Home Blueprint" }
        if model.spreadsheet != nil { return "Import projects" }
        return model.kind == .todos ? "Add to-dos" : "Save to Home Blueprint"
    }

    private var content: some View {
        List {
            Section {
                Picker("This is", selection: $model.kind) {
                    ForEach(model.kindChoices, id: \.self) { kind in
                        Text(choiceTitle(kind)).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                Text(choiceHint)
            }

            if !model.files.isEmpty {
                Section {
                    ForEach(model.files) { f in
                        HStack(spacing: 12) {
                            thumbnail(f)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.file.name).lineLimit(2)
                                Text(SharedInbox.sizeText(f.file.byteSize)).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text(model.files.count == 1 ? "1 file" : "\(model.files.count) files")
                }
            }

            if model.kind == .todos {
                if model.items.isEmpty {
                    Section {
                        Text("No to-dos found in this text. Choose Note to keep it with a project instead.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(Array(model.items.enumerated()), id: \.offset) { _, item in
                            Label(item, systemImage: "circle")
                        }
                    } header: {
                        Text(model.items.count == 1 ? "1 to-do" : "\(model.items.count) to-dos")
                    } footer: {
                        Text("You’ll review them, and choose when and where, in Home Blueprint.")
                    }
                }
            } else if model.hasText {
                Section(model.files.isEmpty ? "Text" : "Message") {
                    Text(model.text).lineLimit(8).font(.callout)
                }
            }

            if !model.problems.isEmpty {
                Section {
                    ForEach(model.problems, id: \.self) { Text($0).foregroundStyle(.orange) }
                }
            }
            if let err = model.errorText {
                Section { Text(err).foregroundStyle(.red) }
            }
        }
    }

    private func choiceTitle(_ kind: SharedInbox.Kind) -> String {
        switch kind {
        case .todos: return "To-dos"
        case .receipt: return "Receipt"
        case .document: return "Document"
        case .note: return model.files.isEmpty ? "Note" : "Message"
        }
    }

    private var choiceHint: String {
        switch model.kind {
        case .todos: return "Each line or item becomes a to-do."
        case .receipt: return "You’ll pick the project or item it’s for. Home reads the total, date and store for you."
        case .document: return "A quote, invoice, warranty or manual. You’ll pick the project or item it belongs to."
        case .note: return "Like a reply from a contractor. You’ll pick the project to keep it with."
        }
    }

    @ViewBuilder
    private func thumbnail(_ f: ReceivedFile) -> some View {
        if let image = f.thumbnail {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(.quaternary))
        } else {
            Image(systemName: f.file.isPDF ? "doc.richtext" : "photo")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 48, height: 48)
        }
    }
}

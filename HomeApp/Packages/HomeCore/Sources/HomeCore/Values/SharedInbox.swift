import Foundation

/// What the share extension hands to the app: shared text and/or files plus what the person said it is.
/// The keychain plumbing lives in the app's `SharedCaptureInbox`; this is the pure, testable part (entry model,
/// limits, small helpers) both the app and the extension use.
public enum SharedInbox {
    /// What the person said the shared thing is (picked in the share sheet).
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// A list → Quick add (the original behavior).
        case todos
        /// A receipt or invoice (photo, screenshot or PDF) → file on a project or item, maybe add the cost.
        case receipt
        /// Any other document (quote, warranty, manual…) → attach to a project or item.
        case document
        /// A message, e.g. a contractor's reply → added to a project's or item's notes.
        case note

        /// Old entries (before kinds existed) and unknown future kinds read as to-dos.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .todos
        }

        public var title: String {
            switch self {
            case .todos: return "To-dos"
            case .receipt: return "Receipt"
            case .document: return "Document"
            case .note: return "Note"
            }
        }
    }

    /// One shared file. Its bytes are stored separately (one keychain item per file, keyed by `id`).
    public struct File: Codable, Hashable, Sendable, Identifiable {
        public var id: UUID
        /// Display name, e.g. "Invoice 1043.pdf" or "Photo.jpg".
        public var name: String
        /// "public.jpeg" or "com.adobe.pdf".
        public var uti: String
        /// "jpg" or "pdf".
        public var fileExt: String
        public var byteSize: Int

        public init(id: UUID = UUID(), name: String, uti: String, fileExt: String, byteSize: Int) {
            self.id = id; self.name = name; self.uti = uti; self.fileExt = fileExt; self.byteSize = byteSize
        }

        public var isPDF: Bool { fileExt == "pdf" || uti == "com.adobe.pdf" }
        public var isImage: Bool { !isPDF }
    }

    /// One share. Entries saved before kinds and files existed decode as `.todos` with no files.
    public struct Entry: Codable, Hashable, Sendable {
        public var text: String
        public var createdAt: Date
        public var kind: Kind
        public var files: [File]

        public init(text: String, createdAt: Date, kind: Kind = .todos, files: [File] = []) {
            self.text = text; self.createdAt = createdAt; self.kind = kind; self.files = files
        }

        private enum CodingKeys: String, CodingKey { case text, createdAt, kind, files }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
            kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .todos
            files = try c.decodeIfPresent([File].self, forKey: .files) ?? []
        }

        /// To-do text goes to Quick add; everything else opens the "File it" sheet.
        public var isTodoList: Bool { kind == .todos && files.isEmpty }
    }

    // MARK: Limits (the extension runs in ~120 MB and the hand-off is the keychain, so keep payloads small)

    /// Most files taken from one share.
    public static let maxFiles = 5
    /// Shared PDFs above this are refused with a friendly message.
    public static let maxPDFBytes = 8 * 1024 * 1024
    /// Most bytes taken from one share (all files together); the rest are left out with a message.
    public static let maxTotalBytes = 16 * 1024 * 1024
    /// Shared photos are downscaled to this long edge…
    public static let maxImageLongEdgePx = 2000
    /// …and saved as JPEG at this quality.
    public static let jpegQuality = 0.7
    /// Longest text kept from one share.
    public static let maxTextCharacters = 20_000

    /// Pixel size after fitting the long edge into `maxLongEdge` (never upscales).
    public static func fittedSize(width: Int, height: Int, maxLongEdge: Int = maxImageLongEdgePx) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (width, height) }
        let longEdge = max(width, height)
        guard longEdge > maxLongEdge else { return (width, height) }
        let scale = Double(maxLongEdge) / Double(longEdge)
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    /// "Too large" message for a PDF, or nil when it fits.
    public static func pdfSizeProblem(byteSize: Int, name: String) -> String? {
        guard byteSize > maxPDFBytes else { return nil }
        let mb = maxPDFBytes / (1024 * 1024)
        return "“\(name)” is too large to share (over \(mb) MB). Save it to Files and attach it from the app instead."
    }

    /// "8.2 MB", "412 KB".
    public static func sizeText(_ bytes: Int) -> String {
        if bytes >= 1024 * 1024 {
            let mb = Double(bytes) / (1024 * 1024)
            return String(format: "%.1f MB", mb)
        }
        return "\(max(1, bytes / 1024)) KB"
    }

    /// Appends shared text to existing notes under a date header ("— Shared Oct 5, 2026 —"), keeping earlier notes.
    public static func appendingNote(_ text: String, to existing: String?, header: String) -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let block = body.isEmpty ? header : "\(header)\n\(body)"
        let old = (existing ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return old.isEmpty ? block : "\(old)\n\n\(block)"
    }

    /// A name for a new project made from a share: the vendor, else the first line of the text, else a default.
    public static func suggestedTitle(vendor: String?, text: String, kind: Kind) -> String {
        if let v = vendor?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
        let firstLine = text.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        if let firstLine { return String(firstLine.prefix(60)) }
        return kind == .receipt ? "New purchase" : "New project"
    }
}

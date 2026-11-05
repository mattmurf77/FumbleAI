import Foundation

/// Unconfirmed document suggestions. Each excerpt points back to the page the owner can inspect.
public enum DocumentField: String, Codable, CaseIterable, Sendable {
    case category, title, issuer, referenceNumber, contractor
    case issuedDate, inspectionDate, finalDate, completionDate, warrantyEnd
    case receiptDate, invoiceDate, receiptTotal, invoiceTotal, estimateTotal

    public var displayName: String {
        switch self {
        case .category: return "Document type"
        case .title: return "Title"
        case .issuer: return "Issuer"
        case .referenceNumber: return "Reference number"
        case .contractor: return "Contractor"
        case .issuedDate: return "Date issued"
        case .inspectionDate: return "Inspection date"
        case .finalDate: return "Final approval date"
        case .completionDate: return "Work completion date"
        case .warrantyEnd: return "Warranty end date"
        case .receiptDate: return "Receipt date"
        case .invoiceDate: return "Invoice date"
        case .receiptTotal: return "Receipt total"
        case .invoiceTotal: return "Invoice total"
        case .estimateTotal: return "Quoted amount"
        }
    }
}

public struct DocumentCandidate: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let field: DocumentField
    public let value: String
    public let excerpt: String
    public let page: Int

    public init(field: DocumentField, value: String, excerpt: String, page: Int) {
        id = UUID(); self.field = field; self.value = value; self.excerpt = excerpt; self.page = page
    }
}

public struct DocumentReading: Equatable, Sendable {
    public var candidates: [DocumentCandidate] = []
    public var totalPages = 0
    /// Number of pages where embedded text or OCR returned legible text.
    public var pagesRead = 0
    public var truncated = false
    public var unreadablePages: [Int] = []
    public var usedOCR = false

    public init() {}
}

import Foundation

public enum HomeDocumentCategory: String, Codable, CaseIterable, Sendable {
    case permit, warranty, estimate, invoice, receipt, inspection, insurance, manual, other
    public var label: String { self == .estimate ? "Contractor quote / estimate" : rawValue.capitalized }
}

/// Private library metadata. Original bytes and their identity are always owned by AttachmentRepository.
public struct HomeDocumentDetails: Codable, Equatable, Sendable {
    public var title: String
    public var originalFilename: String?
    public var category: HomeDocumentCategory
    public var documentDate: LocalDate?
    public var projectId: UUID?
    public var quoteAmount: Money?
    public var confirmedFields: [String: String]
    public init(title: String, originalFilename: String? = nil, category: HomeDocumentCategory = .other, documentDate: LocalDate? = nil, projectId: UUID? = nil, quoteAmount: Money? = nil, confirmedFields: [String: String] = [:]) {
        self.title = title; self.originalFilename = originalFilename; self.category = category; self.documentDate = documentDate; self.projectId = projectId; self.quoteAmount = quoteAmount; self.confirmedFields = confirmedFields
    }
    public func validate() throws {
        if let quoteAmount, category != .estimate || quoteAmount.cents < 0 || quoteAmount.currency.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) == nil {
            throw HomeDocumentError("Enter a nonnegative quoted price and a three-letter currency code.")
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 240,
              (originalFilename?.count ?? 0) <= 512, confirmedFields.count <= 30,
              confirmedFields.allSatisfy({ $0.key.count <= 100 && $0.value.count <= 2048 }) else { throw HomeDocumentError("Enter a title up to 240 characters and keep each confirmed detail under 2,048 characters.") }
    }
}

public struct HomeDocument: Identifiable, Equatable, Sendable {
    public let attachment: Attachment
    public let details: HomeDocumentDetails
    public let linkedProjectId: UUID?
    public var id: UUID { attachment.id }
    public init(attachment: Attachment, details: HomeDocumentDetails?, lineOwners: [UUID: UUID] = [:]) {
        self.attachment = attachment
        let originalOwner = attachment.ownerType == .project ? attachment.ownerId : (attachment.ownerType == .costLineItem ? lineOwners[attachment.ownerId] : nil)
        self.linkedProjectId = details?.projectId ?? originalOwner
        if let details { self.details = details }
        else {
            let category: HomeDocumentCategory = attachment.kind == .receipt ? .receipt : (attachment.kind == .manual ? .manual : .other)
            let label = attachment.kind == .photo ? "Photo" : (category == .other ? "Document" : category.label)
            let caption = attachment.caption?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.details = .init(title: caption.flatMap { $0.isEmpty ? nil : String($0.prefix(240)) } ?? label, category: category)
        }
    }
    public static let exportHeader = ["attachment_id", "project_id", "title", "original_filename", "type", "document_date", "quote_amount", "currency", "confirmed_details_json", "original_file", "status"]
    public func exportRow(includedPath: String?) throws -> [String] {
        [id.uuidString.lowercased(), linkedProjectId?.uuidString.lowercased() ?? "", details.title, details.originalFilename ?? "", details.category.rawValue,
         details.documentDate?.description ?? "", details.quoteAmount?.plainString ?? "", details.quoteAmount?.currency ?? "",
         try HomeJSON.encodeString(details.confirmedFields), includedPath ?? "", includedPath == nil ? "unavailable_on_device" : "included"]
    }
    public func matches(_ query: String, projectName: String? = nil) -> Bool {
        let tokens = query.split(whereSeparator: \.isWhitespace)
        let text = ([details.title, details.category.label, projectName ?? "", details.originalFilename ?? "", details.documentDate?.description ?? ""] + Array(details.confirmedFields.values)).joined(separator: " ")
        return tokens.allSatisfy { text.localizedStandardContains(String($0)) }
    }
}

public struct HomeDocumentError: LocalizedError, Sendable {
    public let errorDescription: String?
    public init(_ description: String) { errorDescription = description }
}

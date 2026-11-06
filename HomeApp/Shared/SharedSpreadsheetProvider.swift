import Foundation
import UniformTypeIdentifiers
import HomeCore

/// Shared by the iOS extension and the import-handoff integration tests.
enum SharedSpreadsheetProvider {
    enum SpreadsheetResult { case file(SharedInbox.Spreadsheet), problem(String) }

    /// Prefer an original file URL or the provider's declared delimited-file representation. Converting its
    /// public.text alternative back into Data would change encoding and may truncate quoted multiline fields.
    static func read(_ provider: NSItemProvider) async -> SpreadsheetResult? {
        let csv = UTType.commaSeparatedText, tsv = UTType.tabSeparatedText
        let offered = provider.registeredTypeIdentifiers.first { id in
            guard let type = UTType(id) else { return false }
            return type.conforms(to: csv) || type.conforms(to: tsv)
        }
        let ext = offered.flatMap { UTType($0)?.conforms(to: tsv) == true ? "tsv" : "csv" }
            ?? SharedInbox.Spreadsheet.fileExtension(name: provider.suggestedName)

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let id = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ? UTType.fileURL.identifier : UTType.url.identifier
            let item = try? await provider.loadItem(forTypeIdentifier: id)
            let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
            if let url, let format = ext ?? SharedInbox.Spreadsheet.fileExtension(name: url.lastPathComponent) {
                if url.isFileURL {
                    return readSpreadsheet(url, name: provider.suggestedName ?? url.lastPathComponent, ext: format)
                }
                if offered == nil { return .problem(SharedInbox.Spreadsheet.openInFiles) }
            }
        }
        guard let ext else { return nil }
        let originalType = offered ?? provider.registeredTypeIdentifiers.first(where: { $0 == UTType.data.identifier })
        guard let originalType else { return .problem(SharedInbox.Spreadsheet.openInFiles) }
        let suggested = provider.suggestedName
        return await withCheckedContinuation { continuation in
            // The temporary provider URL is valid only during this callback.
            _ = provider.loadFileRepresentation(forTypeIdentifier: originalType) { url, _ in
                guard let url, url.isFileURL else {
                    continuation.resume(returning: .problem(SharedInbox.Spreadsheet.openInFiles)); return
                }
                let name = suggested ?? url.lastPathComponent
                continuation.resume(returning: readSpreadsheet(url, name: name, ext: ext))
            }
        }
    }

    private static func readSpreadsheet(_ url: URL, name: String?, ext: String) -> SpreadsheetResult {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do { return .file(try SharedInbox.Spreadsheet.read(url, name: name, ext: ext)) }
        catch let error as ProjectCSVError { return .problem(error.localizedDescription) }
        catch { return .problem(SharedInbox.Spreadsheet.openInFiles) }
    }
}

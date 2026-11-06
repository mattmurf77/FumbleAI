import Foundation
import HomeCore
#if canImport(Security)
import Security
#endif

/// Hand-off from the share extension to the app: text, receipt photos and PDFs shared from Notes, Mail, Messages,
/// Photos or any app wait here until the app next comes to the foreground. To-do lists then open in Quick add;
/// receipts, documents and notes open the "File it" sheet.
///
/// Stored in a keychain access group both targets carry (`HomeKeychainGroup` in their Info.plist,
/// `$(AppIdentifierPrefix)$(HOME_BUNDLE_ID).shared`). Keychain groups within one team need no App Group or portal
/// setup. The index of entries is one item (service `HomeBlueprint.CaptureInbox`, account `pending`); each file's
/// bytes are their own item (service `HomeBlueprint.CaptureInbox.file`, account = the file's id), so the index stays
/// small. Entry model and limits: `HomeCore.SharedInbox`. Compiled into both the app and the extension.
enum SharedCaptureInbox {
    typealias Entry = SharedInbox.Entry

    /// One shared file's metadata and bytes.
    struct Payload {
        var file: SharedInbox.File
        var data: Data
    }

    /// An entry as the app receives it, with its files' bytes (files whose bytes went missing are dropped).
    struct Taken {
        var entry: Entry
        var payloads: [Payload]
    }

    private static let service = "HomeBlueprint.CaptureInbox"
    private static let account = "pending"
    private static let fileService = "HomeBlueprint.CaptureInbox.file"
    /// Keep the hand-off small; longer shares are trimmed.
    static let maxCharacters = SharedInbox.maxTextCharacters

    private static var accessGroup: String? {
        let group = Bundle.main.object(forInfoDictionaryKey: "HomeKeychainGroup") as? String
        guard let group, !group.isEmpty, !group.contains("$(") else { return nil }
        return group
    }

    /// Adds shared to-do text to the inbox. Returns false when the keychain refused it.
    @discardableResult
    static func append(_ text: String, now: Date = Date()) -> Bool {
        append(kind: .todos, text: text, payloads: [], now: now)
    }

    /// Adds a share: its kind, any text, and files (each stored as its own keychain item). All or nothing: when
    /// any write fails, the files already written are removed and false is returned.
    @discardableResult
    static func append(kind: SharedInbox.Kind, text: String, payloads: [Payload], now: Date = Date()) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !payloads.isEmpty else { return false }
        var written: [UUID] = []
        for p in payloads {
            guard writeFile(p.data, id: p.file.id) else {
                written.forEach(deleteFile)
                return false
            }
            written.append(p.file.id)
        }
        var entries = read()
        entries.append(Entry(text: String(trimmed.prefix(maxCharacters)), createdAt: now, kind: kind,
                             files: payloads.map(\.file)))
        guard write(entries) else {
            written.forEach(deleteFile)
            return false
        }
        return true
    }

    /// Everything waiting, oldest first, with the files' bytes; the inbox (index and files) is emptied.
    static func takeAll() -> [Taken] {
        let entries = read()
        guard !entries.isEmpty else { return [] }
        let taken = entries.map { entry in
            Taken(entry: entry, payloads: entry.files.compactMap { f in readFile(f.id).map { Payload(file: f, data: $0) } })
        }
        delete()
        for entry in entries { entry.files.map(\.id).forEach(deleteFile) }
        return taken
    }

    /// One keychain item per spreadsheet avoids racing the shared text/PDF queue. Reading does not consume it.
    /// Keep the payload until the owner closes the import review; relaunch can recover an interrupted review.
    private static let spreadsheetService = "HomeBlueprint.CaptureInbox.spreadsheet"
    struct PendingSpreadsheet: Identifiable {
        let id: UUID
        let file: SharedInbox.Spreadsheet?
    }

    static func saveSpreadsheet(_ file: SharedInbox.Spreadsheet) -> Bool {
        guard accessGroup != nil, !file.bytes.isEmpty, file.bytes.count <= ProjectCSV.maxBytes else { return false }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let key = UUID().uuidString.lowercased()
        guard let data = try? encoder.encode(file), writeData(data, service: spreadsheetService, account: key) else { return false }
        guard readData(service: spreadsheetService, account: key) == data else {
            deleteData(service: spreadsheetService, account: key)
            return false
        }
        return true
    }

    static func nextSpreadsheet() -> PendingSpreadsheet? {
        #if canImport(Security)
        guard let accessGroup else { return nil }
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: spreadsheetService,
            kSecAttrAccessGroup as String: accessGroup, kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let rows = result as? [[String: Any]] else { return nil }
        let ids = rows.compactMap { row -> (String, Date)? in
            guard let key = row[kSecAttrAccount as String] as? String, UUID(uuidString: key) != nil else { return nil }
            return (key, row[kSecAttrCreationDate as String] as? Date ?? .distantPast)
        }.sorted { ($0.1, $0.0) < ($1.1, $1.0) }
        guard let key = ids.first?.0, let id = UUID(uuidString: key),
              let data = readData(service: spreadsheetService, account: key) else { return nil }
        let file = try? PropertyListDecoder().decode(SharedInbox.Spreadsheet.self, from: data)
        guard let file, !file.bytes.isEmpty, file.bytes.count <= ProjectCSV.maxBytes,
              SharedInbox.Spreadsheet.fileExtension(name: file.name) != nil else { return .init(id: id, file: nil) }
        return .init(id: id, file: file)
        #else
        return nil
        #endif
    }

    static func finishSpreadsheet(_ id: UUID) {
        deleteData(service: spreadsheetService, account: id.uuidString.lowercased())
    }

    // MARK: Keychain

    #if canImport(Security)
    private static func query(service: String, account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    private static func readData(service: String, account: String) -> Data? {
        var q = query(service: service, account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func writeData(_ data: Data, service: String, account: String) -> Bool {
        let base = query(service: service, account: account)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func deleteData(service: String, account: String) {
        SecItemDelete(query(service: service, account: account) as CFDictionary)
    }
    #else
    private static func readData(service: String, account: String) -> Data? { nil }
    private static func writeData(_ data: Data, service: String, account: String) -> Bool { false }
    private static func deleteData(service: String, account: String) {}
    #endif

    private static func read() -> [Entry] {
        guard let data = readData(service: service, account: account) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private static func write(_ entries: [Entry]) -> Bool {
        guard let data = try? JSONEncoder().encode(entries) else { return false }
        return writeData(data, service: service, account: account)
    }

    private static func delete() { deleteData(service: service, account: account) }

    private static func fileAccount(_ id: UUID) -> String { id.uuidString.lowercased() }
    private static func readFile(_ id: UUID) -> Data? { readData(service: fileService, account: fileAccount(id)) }
    private static func writeFile(_ data: Data, id: UUID) -> Bool { writeData(data, service: fileService, account: fileAccount(id)) }
    private static func deleteFile(_ id: UUID) { deleteData(service: fileService, account: fileAccount(id)) }
}

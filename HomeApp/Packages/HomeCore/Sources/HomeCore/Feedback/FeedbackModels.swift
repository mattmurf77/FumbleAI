import Foundation

/// In-app feedback (Settings-independent, available on every screen). Sent to the Home server
/// `POST {HomeServerURL}/v1/feedback` and stored in Render Postgres. See `server/README.md`.
///
/// Privacy: only what the user types, the page name, app/iOS version, device model identifier and a random
/// install id. No screenshots, names, emails, locations or home data.
public enum FeedbackCategory: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case bug
    case polish
    case idea

    public var id: String { rawValue }

    /// Segmented-control title.
    public var displayName: String {
        switch self {
        case .bug: return "Bug"
        case .polish: return "Polish"
        case .idea: return "Idea"
        }
    }

    /// SF Symbol name.
    public var symbolName: String {
        switch self {
        case .bug: return "ladybug"
        case .polish: return "sparkles"
        case .idea: return "lightbulb"
        }
    }

    /// Placeholder for the message field.
    public var prompt: String {
        switch self {
        case .bug: return "What went wrong? What did you expect?"
        case .polish: return "What feels rough, slow or confusing?"
        case .idea: return "What would make Home Blueprint better?"
        }
    }
}

/// One piece of feedback as the app sends it. Encodes to the server's JSON shape (camelCase keys).
public struct FeedbackSubmission: Codable, Hashable, Sendable, Identifiable {
    /// Server limit on `message` (characters, after trimming).
    public static let maxMessageLength = 5000
    /// Server limit on `page`.
    public static let maxPageLength = 200

    /// Client-side id, used to de-duplicate the offline queue. Not sent to the server.
    public var id: UUID
    public var category: FeedbackCategory
    public var message: String
    /// Screen the user was on, e.g. "Plan · Ground floor".
    public var page: String?
    /// Small non-personal screen details (e.g. lens, floor name). Keep it tiny: the server caps it at 4 KB.
    public var screenContext: [String: String]
    public var appVersion: String?
    public var buildNumber: String?
    public var osVersion: String?
    /// `utsname.machine`, e.g. "iPhone15,2".
    public var deviceModel: String?
    /// Random UUID created on first use and kept in UserDefaults; not tied to the user or iCloud.
    public var installId: String?
    /// When the user tapped Send (device clock). Sent inside `screenContext` as `clientCreatedAt`.
    public var createdAt: Date

    public init(id: UUID = UUID(), category: FeedbackCategory, message: String, page: String? = nil,
                screenContext: [String: String] = [:], appVersion: String? = nil, buildNumber: String? = nil,
                osVersion: String? = nil, deviceModel: String? = nil, installId: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.category = category
        self.message = message
        self.page = page
        self.screenContext = screenContext
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.installId = installId
        self.createdAt = createdAt
    }

    /// The message as it will be stored (whitespace trimmed).
    public var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// True when the server will accept the message (1…5,000 characters after trimming).
    public var isValid: Bool {
        let count = trimmedMessage.unicodeScalars.count
        return count >= 1 && count <= Self.maxMessageLength
    }

    /// JSON body for `POST /v1/feedback`.
    public func requestBody() throws -> Data {
        var context = screenContext
        context["clientCreatedAt"] = Self.isoFormatter.string(from: createdAt)
        let page = self.page?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = RequestBody(
            category: category.rawValue,
            message: trimmedMessage,
            page: page.flatMap { $0.isEmpty ? nil : String($0.prefix(Self.maxPageLength)) },
            screenContext: context,
            appVersion: appVersion, buildNumber: buildNumber, osVersion: osVersion,
            deviceModel: deviceModel, installId: installId)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(body)
    }

    private struct RequestBody: Encodable {
        var category: String
        var message: String
        var page: String?
        var screenContext: [String: String]
        var appVersion: String?
        var buildNumber: String?
        var osVersion: String?
        var deviceModel: String?
        var installId: String?
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

/// What happened to a submission.
public struct FeedbackReceipt: Hashable, Sendable {
    public enum Status: String, Hashable, Sendable {
        /// Stored on the server.
        case sent
        /// Saved on this iPhone (offline, server not configured or unreachable); sent on a later foreground.
        case queued
    }

    public var status: Status
    /// Server id when `status == .sent`.
    public var serverId: String?

    public init(status: Status, serverId: String? = nil) {
        self.status = status
        self.serverId = serverId
    }

    public static let queued = FeedbackReceipt(status: .queued)
}

/// Errors the user must act on (anything retryable is queued instead of thrown).
public enum FeedbackError: Error, Equatable, Sendable, LocalizedError {
    /// Empty or longer than 5,000 characters.
    case invalidMessage
    /// The server rejected the content (HTTP 400/413); retrying won't help.
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .invalidMessage:
            return "Please write between 1 and \(FeedbackSubmission.maxMessageLength) characters."
        case .rejected(let reason):
            return "The server didn’t accept this feedback: \(reason)"
        }
    }
}

/// Sends feedback (live: Home server with an offline queue; previews/tests: in memory).
public protocol FeedbackSubmitting: Sendable {
    /// Sends now, or queues on device when the server is unreachable or not configured. Throws `FeedbackError`
    /// only for problems the user must fix.
    func submit(_ submission: FeedbackSubmission) async throws -> FeedbackReceipt
    /// Retries queued submissions (called on launch and every foreground). Returns how many were sent.
    @discardableResult
    func retryPending() async -> Int
    /// Number of submissions waiting on this iPhone.
    func pendingCount() async -> Int
}

public extension FeedbackSubmitting {
    @discardableResult
    func retryPending() async -> Int { 0 }
    func pendingCount() async -> Int { 0 }
}

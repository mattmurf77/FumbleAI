import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import HomeCore

/// Live `FeedbackSubmitting`: `POST {HomeServerURL}/v1/feedback` with `AppConfig.serverHeaders`.
/// When no server is configured, the phone is offline or the server is asleep/unreachable, the submission is
/// saved in `Application Support/Feedback/pending.json` and retried on every foreground (and once shortly after a
/// failed send, because a sleeping free Render service wakes up on the first request).
/// Only content errors (HTTP 400/413) are thrown; everything else is queued.
actor FeedbackClient: FeedbackSubmitting {
    private let config: AppConfig
    private let session: URLSession
    private let outbox: FeedbackOutbox
    private let requestTimeout: TimeInterval
    private let followUpDelay: UInt64
    private var retrying = false
    private var followUp: Task<Void, Never>?

    init(config: AppConfig,
         session: URLSession = .shared,
         outbox: FeedbackOutbox = FeedbackOutbox(fileURL: FeedbackOutbox.defaultFileURL),
         requestTimeout: TimeInterval = 20,
         followUpDelaySeconds: Double = 45) {
        self.config = config
        self.session = session
        self.outbox = outbox
        self.requestTimeout = requestTimeout
        self.followUpDelay = UInt64(max(0, followUpDelaySeconds) * 1_000_000_000)
    }

    func submit(_ submission: FeedbackSubmission) async throws -> FeedbackReceipt {
        guard submission.isValid else { throw FeedbackError.invalidMessage }
        switch await send(submission) {
        case .sent(let id):
            return FeedbackReceipt(status: .sent, serverId: id)
        case .rejected(let reason):
            throw FeedbackError.rejected(reason)
        case .retryLater:
            await outbox.append(submission)
            scheduleFollowUp()
            return .queued
        }
    }

    @discardableResult
    func retryPending() async -> Int {
        guard !retrying, config.serverURL != nil else { return 0 }
        retrying = true
        defer { retrying = false }
        var sent = 0
        for item in await outbox.all() {
            switch await send(item) {
            case .sent:
                sent += 1
                await outbox.remove(id: item.id)
            case .rejected:
                // The server will never accept it (e.g. rules changed); drop it rather than retry forever.
                await outbox.remove(id: item.id)
            case .retryLater:
                return sent   // still offline / asleep: keep the rest for the next foreground
            }
        }
        return sent
    }

    func pendingCount() async -> Int { await outbox.all().count }

    // MARK: Sending

    enum SendResult: Equatable {
        case sent(String?)
        case rejected(String)
        case retryLater
    }

    private func send(_ submission: FeedbackSubmission) async -> SendResult {
        guard let base = config.serverURL else { return .retryLater }
        var request = URLRequest(url: base.appendingPathComponent("v1/feedback"), timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in config.serverHeaders { request.setValue(value, forHTTPHeaderField: name) }
        do {
            request.httpBody = try submission.requestBody()
        } catch {
            return .rejected("couldn’t encode the message")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .retryLater
        }
        guard let http = response as? HTTPURLResponse else { return .retryLater }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        switch http.statusCode {
        case 200..<300:
            return .sent(json?["id"] as? String)
        case 400, 413:
            return .rejected((json?["message"] as? String) ?? "HTTP \(http.statusCode)")
        default:
            // 401 (key mismatch), 404 (older server), 429, 5xx, 503 (no database yet): try again later.
            return .retryLater
        }
    }

    private func scheduleFollowUp() {
        guard followUp == nil, config.serverURL != nil, followUpDelay > 0 else { return }
        let delay = followUpDelay
        followUp = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            await self?.finishFollowUp()
        }
    }

    private func finishFollowUp() async {
        followUp = nil
        await retryPending()
    }
}

/// On-disk queue of unsent feedback: one small JSON array. Capped at 100 items; items older than 30 days are
/// dropped. Writes are atomic; a corrupt file is treated as empty.
actor FeedbackOutbox {
    static let maxItems = 100
    static let maxAge: TimeInterval = 30 * 86_400

    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Feedback", isDirectory: true).appendingPathComponent("pending.json")
    }

    private let fileURL: URL
    private let now: @Sendable () -> Date
    private var cache: [FeedbackSubmission]?

    init(fileURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
    }

    func all() -> [FeedbackSubmission] {
        let cutoff = now().addingTimeInterval(-Self.maxAge)
        let items = load()
        let fresh = items.filter { $0.createdAt >= cutoff }
        if fresh.count != items.count { save(fresh) }
        return fresh
    }

    func append(_ submission: FeedbackSubmission) {
        var items = load().filter { $0.id != submission.id }
        items.append(submission)
        if items.count > Self.maxItems { items.removeFirst(items.count - Self.maxItems) }
        save(items)
    }

    func remove(id: UUID) {
        save(load().filter { $0.id != id })
    }

    private func load() -> [FeedbackSubmission] {
        if let cache { return cache }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let items = (try? Data(contentsOf: fileURL)).flatMap { try? decoder.decode([FeedbackSubmission].self, from: $0) } ?? []
        cache = items
        return items
    }

    private func save(_ items: [FeedbackSubmission]) {
        cache = items
        do {
            if items.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(items).write(to: fileURL, options: [.atomic])
        } catch {
            // Keep the in-memory copy; the next successful write persists it.
        }
    }
}

/// Non-personal device details attached to feedback.
enum FeedbackDeviceInfo {
    static let installIdKey = "feedback.installId"

    /// iOS version, e.g. "17.5.1".
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
    }

    /// Model identifier from `utsname`, e.g. "iPhone15,2" (the Simulator reports the simulated model).
    static var deviceModel: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "\(simulated) (Simulator)"
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Random id made on first use and kept in UserDefaults. Lets the founder group feedback from one install
    /// without knowing who it is; reinstalling the app makes a new one.
    static func installId(defaults: UserDefaults = .standard) -> String {
        if let id = defaults.string(forKey: installIdKey), !id.isEmpty { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: installIdKey)
        return id
    }

    /// A submission with app/device metadata filled in.
    static func submission(category: FeedbackCategory, message: String, page: String?, context: [String: String],
                           config: AppConfig, defaults: UserDefaults = .standard) -> FeedbackSubmission {
        FeedbackSubmission(category: category, message: message, page: page, screenContext: context,
                           appVersion: config.appVersion, buildNumber: config.buildNumber,
                           osVersion: osVersion, deviceModel: deviceModel, installId: installId(defaults: defaults))
    }
}

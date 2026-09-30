import Foundation
import HomeCore

/// `FeedbackSubmitting` for previews and tests: keeps submissions in memory.
/// Set `offline = true` to exercise the "Saved — will send when online" path; `retryPending()` then sends them
/// once `offline` is false again.
public final class InMemoryFeedbackSubmitter: FeedbackSubmitting, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [FeedbackSubmission] = []
    private var _pending: [FeedbackSubmission] = []
    private var _offline: Bool

    public init(offline: Bool = false) {
        _offline = offline
    }

    /// Submissions the "server" received, oldest first.
    public var sent: [FeedbackSubmission] { lock.withLock { _sent } }
    /// Submissions waiting while offline.
    public var pending: [FeedbackSubmission] { lock.withLock { _pending } }
    public var offline: Bool {
        get { lock.withLock { _offline } }
        set { lock.withLock { _offline = newValue } }
    }

    public func submit(_ submission: FeedbackSubmission) async throws -> FeedbackReceipt {
        guard submission.isValid else { throw FeedbackError.invalidMessage }
        return lock.withLock {
            if _offline {
                _pending.append(submission)
                return .queued
            }
            _sent.append(submission)
            return FeedbackReceipt(status: .sent, serverId: submission.id.uuidString.lowercased())
        }
    }

    @discardableResult
    public func retryPending() async -> Int {
        lock.withLock {
            guard !_offline else { return 0 }
            let n = _pending.count
            _sent.append(contentsOf: _pending)
            _pending.removeAll()
            return n
        }
    }

    public func pendingCount() async -> Int { lock.withLock { _pending.count } }
}

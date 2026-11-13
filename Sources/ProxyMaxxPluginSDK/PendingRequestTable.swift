import Foundation

/// Correlates outstanding requests with their continuations. Lock-based rather
/// than actor-based so task cancellation handlers can cancel synchronously.
final class PendingRequestTable: @unchecked Sendable {
    /// The reply the bridge resolves a pending request with.
    enum Reply {
        case status(PermissionStatus)
        case statuses([String: PermissionStatus])
        case cancelled
    }

    static let maxOutstanding = 64

    private let lock = NSLock()
    private var pending: [String: CheckedContinuation<Reply, Error>] = [:]
    /// Ids cancelled before their request registered (the cancellation handler
    /// of an already-cancelled task can run before the operation body does).
    private var cancelledIds: Set<String> = []

    /// Cancels a request. Returns `true` when it was pending and has been
    /// resumed with `CancellationError`; otherwise the id is recorded so a
    /// late registration fails immediately.
    @discardableResult
    func cancel(_ requestId: String) -> Bool {
        lock.lock()
        if let continuation = pending.removeValue(forKey: requestId) {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return true
        }
        cancelledIds.insert(requestId)
        lock.unlock()
        return false
    }

    /// Resolves a pending request with a reply. Returns `false` when the id is
    /// unknown (already cancelled or already fulfilled); such replies are
    /// ignored by the reader.
    @discardableResult
    func fulfill(_ requestId: String, with reply: Reply) -> Bool {
        lock.lock()
        let continuation = pending.removeValue(forKey: requestId)
        lock.unlock()
        guard let continuation else { return false }
        continuation.resume(returning: reply)
        return true
    }

    /// Fails one pending request. Returns `false` when the id is unknown.
    @discardableResult
    func fail(_ requestId: String, with error: Error) -> Bool {
        lock.lock()
        let continuation = pending.removeValue(forKey: requestId)
        lock.unlock()
        guard let continuation else { return false }
        continuation.resume(throwing: error)
        return true
    }

    /// Fails and clears every outstanding request.
    func failAll(with error: Error) {
        lock.lock()
        let continuations = Array(pending.values)
        pending.removeAll()
        lock.unlock()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    /// Awaits a reply for `requestId`. `onStart` runs after the continuation is
    /// registered and should send the wire message; if it throws, the request
    /// is failed with that error.
    ///
    /// Throws `CancellationError` immediately when the id was cancelled before
    /// registration, and `PermissionError.hostUnavailable` when the table is
    /// full or the id is already in use.
    func awaitReply(
        for requestId: String,
        onStart: @Sendable () throws -> Void
    ) async throws -> Reply {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if pending.count >= Self.maxOutstanding || pending[requestId] != nil {
                lock.unlock()
                continuation.resume(throwing: PermissionError.hostUnavailable)
                return
            }
            if cancelledIds.contains(requestId) {
                cancelledIds.remove(requestId)
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            pending[requestId] = continuation
            lock.unlock()

            do {
                try onStart()
            } catch {
                // If a reply resolved the request between registration and this
                // failure, the resumed reply wins and this is a no-op.
                fail(requestId, with: error)
            }
        }
    }
}

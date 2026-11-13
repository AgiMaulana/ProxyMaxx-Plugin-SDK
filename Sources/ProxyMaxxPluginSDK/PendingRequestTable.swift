import Foundation

/// Correlates outstanding requests with their continuations. Lock-based rather
/// than actor-based so task cancellation handlers can cancel synchronously.
///
/// Request lifecycle: `notYetRegistered → pending → resolved`, with a
/// cancellation that can arrive at any point. Exactly-once resolution is
/// structural: a continuation is removed from the pending table under the lock
/// before it is resumed, so no path can resume twice.
///
/// Bookkeeping is bounded: at most `maxOutstanding` pending continuations and
/// `maxResolvedHistory` remembered resolved ids. Cancellation-before-
/// registration is recorded in a bounded set that is consumed when the request
/// registers (a registration for an evicted id still fails because `send`
/// re-checks `Task.isCancelled`).
final class PendingRequestTable: @unchecked Sendable {
    /// The reply the bridge resolves a pending request with.
    enum Reply {
        case status(PermissionStatus)
        case statuses([String: PermissionStatus])
        case cancelled
    }

    static let maxOutstanding = 64
    /// How many recently resolved ids are remembered so late cancellations do
    /// not create bookkeeping for requests that already finished (SDK-03 5.4).
    static let maxResolvedHistory = 128

    private let lock = NSLock()
    private var pending: [String: CheckedContinuation<Reply, Error>] = [:]
    /// Ids cancelled before their request registered.
    private var cancelledIds: [String] = []
    private var cancelledIdSet: Set<String> = []
    /// Recently resolved ids, oldest first; bounded by `maxResolvedHistory`.
    private var resolvedHistory: [String] = []
    private var resolvedHistorySet: Set<String> = []

    /// Cancels a request. Returns `true` when it was pending and has been
    /// resumed with `CancellationError` (the bridge then sends exactly one
    /// `permission.cancel`). Returns `false` when the request already resolved
    /// (no bookkeeping, no message) or must record a pre-registration
    /// cancellation.
    @discardableResult
    func cancel(_ requestId: String) -> Bool {
        lock.lock()
        if let continuation = pending.removeValue(forKey: requestId) {
            rememberResolved(requestId)
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return true
        }
        if resolvedHistorySet.contains(requestId) {
            // Already resolved; a late cancellation must not create bookkeeping.
            lock.unlock()
            return false
        }
        rememberCancelledBeforeRegistration(requestId)
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
        if continuation != nil {
            rememberResolved(requestId)
        }
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
        if continuation != nil {
            rememberResolved(requestId)
        }
        lock.unlock()
        guard let continuation else { return false }
        continuation.resume(throwing: error)
        return true
    }

    /// Fails and clears every outstanding request. Resolved history is kept so
    /// late cancellations after a channel failure create no bookkeeping.
    func failAll(with error: Error) {
        lock.lock()
        let continuations = Array(pending.values)
        for id in pending.keys {
            rememberResolved(id)
        }
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
            if cancelledIdSet.contains(requestId) {
                removeCancelledBeforeRegistration(requestId)
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

    // MARK: Test introspection

    var outstandingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    /// Total bookkeeping entries: pending + pre-registration cancellations.
    var bookkeepingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count + cancelledIds.count
    }

    // MARK: Private (call with lock held)

    private func rememberResolved(_ requestId: String) {
        if !resolvedHistorySet.contains(requestId) {
            resolvedHistory.append(requestId)
            resolvedHistorySet.insert(requestId)
        }
        if resolvedHistory.count > Self.maxResolvedHistory {
            let evicted = resolvedHistory.removeFirst()
            resolvedHistorySet.remove(evicted)
        }
        // Resolution also clears any pre-registration cancellation record: the
        // request can no longer be cancelled.
        removeCancelledBeforeRegistration(requestId)
    }

    private func rememberCancelledBeforeRegistration(_ requestId: String) {
        if cancelledIdSet.insert(requestId).inserted {
            cancelledIds.append(requestId)
        }
        if cancelledIds.count > Self.maxOutstanding {
            let evicted = cancelledIds.removeFirst()
            cancelledIdSet.remove(evicted)
        }
    }

    private func removeCancelledBeforeRegistration(_ requestId: String) {
        if cancelledIdSet.remove(requestId) != nil {
            if let index = cancelledIds.firstIndex(of: requestId) {
                cancelledIds.remove(at: index)
            }
        }
    }
}

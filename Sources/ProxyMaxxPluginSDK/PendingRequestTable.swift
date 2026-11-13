import Foundation

/// Correlates outstanding requests with their continuations. Lock-based rather
/// than actor-based so task cancellation handlers can cancel synchronously.
///
/// Request lifecycle: `notYetRegistered → pending → resolved`. Cancellation is
/// detected through the task's own cancellation state, never through per-id
/// bookkeeping:
///
/// - Cancelled **before registration**: the handler finds nothing pending and
///   sends no wire message; registration then observes `Task.isCancelled`
///   under the same lock and throws. Because the check and the pending insert
///   are one critical section, a cancel event is always observed by exactly
///   one side of it — no id-record races, no eviction hazards.
/// - Cancelled **while pending**: the handler pops the continuation, resumes
///   it with `CancellationError`, and the bridge sends exactly one
///   `permission.cancel`.
/// - Cancelled **after resolution**: the id is in the resolved history, so the
///   handler does nothing. No bookkeeping is created for a finished request.
///
/// Exactly-once resolution is structural: a continuation is removed from the
/// pending table under the lock before it is resumed, so no path can resume
/// twice.
///
/// All bookkeeping is bounded: at most `maxOutstanding` pending continuations
/// and `maxResolvedHistory` remembered resolved ids. Nothing else is kept.
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
    /// Recently resolved ids, oldest first; bounded by `maxResolvedHistory`.
    private var resolvedHistory: [String] = []
    private var resolvedHistorySet: Set<String> = []

    /// Cancels a request. Returns `true` when it was pending and has been
    /// resumed with `CancellationError` (the bridge then sends exactly one
    /// `permission.cancel`). Returns `false` when the request has not
    /// registered yet (its registration will observe `Task.isCancelled`) or
    /// already resolved — in both cases no bookkeeping and no message.
    @discardableResult
    func cancel(_ requestId: String) -> Bool {
        lock.lock()
        if let continuation = pending.removeValue(forKey: requestId) {
            rememberResolved(requestId)
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return true
        }
        lock.unlock()
        // Not pending: either still unregistered (registration will see the
        // cancelled task) or already resolved (in the resolved history).
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
    /// The capacity/duplicate/cancellation checks and the pending insert are a
    /// single critical section: a cancellation handler either runs before it
    /// (and `Task.isCancelled` catches the request here) or after it (and the
    /// handler pops the pending continuation). There is no window in between.
    ///
    /// Throws `CancellationError` when the task is already cancelled, and
    /// `PermissionError.hostUnavailable` when the table is full or the id is
    /// already in use.
    func awaitReply(
        for requestId: String,
        onStart: @Sendable () throws -> Void
    ) async throws -> Reply {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if Task.isCancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            if pending.count >= Self.maxOutstanding || pending[requestId] != nil {
                lock.unlock()
                continuation.resume(throwing: PermissionError.hostUnavailable)
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

    /// Cancellation/lifecycle bookkeeping: just the pending continuations.
    /// Pre-registration cancellations keep no records (detected via
    /// `Task.isCancelled`), and resolved history is a bounded cache, not
    /// lifecycle state.
    var bookkeepingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    /// Entries in the bounded resolved-id cache.
    var resolvedHistoryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return resolvedHistory.count
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
    }
}

import Foundation

/// The default `PermissionHostBridge`: JSON-lines over the plugin's stdin/stdout
/// channel, protocol v1 (see `Docs/PROTOCOL.md`).
///
/// The reader task runs for the lifetime of the bridge. Replies are correlated
/// by request id; a reply whose id is unknown is ignored. Any malformed reply
/// (undecodable line, unknown status, missing request id) fails every
/// outstanding request with `PermissionError.hostUnavailable` — the SDK never
/// guesses at an unverifiable host reply.
public final class JSONLinesBridge: PermissionHostBridge, @unchecked Sendable {
    private let lineSource: LineSource
    private let sink: LineSink
    private let table = PendingRequestTable()

    private let stateLock = NSLock()
    private var channelClosed = false

    private var readerTask: Task<Void, Never> = Task {}

    /// Bridge over the host runner's stdin/stdout channel.
    public convenience init() {
        self.init(
            lineSource: FileHandleLineSource(handle: FileHandle.standardInput),
            sink: FileHandleLineSink(handle: FileHandle.standardOutput)
        )
    }

    /// Bridge over explicit channel endpoints. Used by tests and embedders.
    public init(lineSource: LineSource, sink: LineSink) {
        self.lineSource = lineSource
        self.sink = sink
        readerTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.runReader()
        }
    }

    deinit {
        readerTask.cancel()
    }

    // MARK: PermissionHostBridge

    public func request(_ permissionId: String) async throws -> PermissionStatus {
        let reply = try await send(
            requestId: UUID().uuidString,
            message: { ["kind": "permission.request", "requestId": $0, "permissionId": permissionId] }
        )
        switch reply {
        case .status(let status):
            // Spec §6: a successful request must not surface NOT_REQUESTED.
            guard status != .notRequested else { throw PermissionError.hostUnavailable }
            return status
        case .statuses:
            throw PermissionError.hostUnavailable
        case .cancelled:
            throw CancellationError()
        }
    }

    public func requestAll(_ permissionIds: [String]) async throws -> [String: PermissionStatus] {
        let ids = permissionIds
        let reply = try await send(
            requestId: UUID().uuidString,
            message: { ["kind": "permission.requestAll", "requestId": $0, "permissionIds": ids] }
        )
        switch reply {
        case .statuses(let statuses):
            return try validated(statuses: statuses, for: ids, allowNotRequested: false)
        default:
            throw PermissionError.hostUnavailable
        }
    }

    public func check(_ permissionId: String) async throws -> PermissionStatus {
        let reply = try await send(
            requestId: UUID().uuidString,
            message: { ["kind": "permission.check", "requestId": $0, "permissionId": permissionId] }
        )
        switch reply {
        case .status(let status):
            return status
        default:
            throw PermissionError.hostUnavailable
        }
    }

    public func checkAll(_ permissionIds: [String]) async throws -> [String: PermissionStatus] {
        let ids = permissionIds
        let reply = try await send(
            requestId: UUID().uuidString,
            message: { ["kind": "permission.checkAll", "requestId": $0, "permissionIds": ids] }
        )
        switch reply {
        case .statuses(let statuses):
            return try validated(statuses: statuses, for: ids, allowNotRequested: true)
        default:
            throw PermissionError.hostUnavailable
        }
    }

    // MARK: Internals

    private func send(
        requestId: String,
        message: @escaping @Sendable (String) -> [String: Any]
    ) async throws -> PendingRequestTable.Reply {
        guard !isChannelClosed() else { throw PermissionError.hostUnavailable }
        if Task.isCancelled { throw CancellationError() }

        return try await withTaskCancellationHandler {
            try await table.awaitReply(for: requestId) { [sink] in
                try sink.write(message(requestId))
            }
        } onCancel: { [table, sink] in
            if table.cancel(requestId) {
                try? sink.write([
                    "kind": "permission.cancel",
                    "requestId": requestId,
                ])
            }
        }
    }

    /// Validates a batch reply: every requested id must be present (fail closed
    /// on gaps), extras are dropped, and `NOT_REQUESTED` is rejected when the
    /// batch is a consent-bearing request.
    private func validated(
        statuses: [String: PermissionStatus],
        for ids: [String],
        allowNotRequested: Bool
    ) throws -> [String: PermissionStatus] {
        var result: [String: PermissionStatus] = [:]
        for id in ids {
            guard let status = statuses[id] else { throw PermissionError.hostUnavailable }
            if !allowNotRequested && status == .notRequested {
                throw PermissionError.hostUnavailable
            }
            result[id] = status
        }
        return result
    }

    private func runReader() async {
        while true {
            let line: String?
            do {
                line = try await lineSource.readLine()
            } catch {
                failChannel(with: PermissionError.hostUnavailable)
                return
            }
            guard let line else {
                failChannel(with: PermissionError.hostUnavailable)
                return
            }
            handle(line)
        }
    }

    private func failChannel(with error: Error) {
        markChannelClosed()
        table.failAll(with: error)
    }

    private func isChannelClosed() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return channelClosed
    }

    private func markChannelClosed() {
        stateLock.lock()
        channelClosed = true
        stateLock.unlock()
    }

    private func handle(_ line: String) {
        guard let object = JSONLines.decode(line) else {
            failChannel(with: PermissionError.hostUnavailable)
            return
        }

        switch object["kind"] as? String {
        case "permission.status":
            guard let requestId = object["requestId"] as? String,
                  let raw = object["status"] as? String,
                  let status = PermissionStatus(wireString: raw) else {
                failChannel(with: PermissionError.hostUnavailable)
                return
            }
            table.fulfill(requestId, with: .status(status))

        case "permission.statuses":
            guard let requestId = object["requestId"] as? String,
                  let rawStatuses = object["statuses"] as? [String: String] else {
                failChannel(with: PermissionError.hostUnavailable)
                return
            }
            var statuses: [String: PermissionStatus] = [:]
            for (id, raw) in rawStatuses {
                guard let status = PermissionStatus(wireString: raw) else {
                    failChannel(with: PermissionError.hostUnavailable)
                    return
                }
                statuses[id] = status
            }
            table.fulfill(requestId, with: .statuses(statuses))

        case "permission.cancelled":
            // The user dismissed or cancelled the consent UI. Propagate as
            // cancellation; the host must not substitute a status here.
            guard let requestId = object["requestId"] as? String else {
                failChannel(with: PermissionError.hostUnavailable)
                return
            }
            table.fulfill(requestId, with: .cancelled)

        case "permission.error":
            guard let requestId = object["requestId"] as? String else {
                failChannel(with: PermissionError.hostUnavailable)
                return
            }
            table.fail(requestId, with: PermissionError.hostUnavailable)

        default:
            // Unknown message kinds are ignored; they do not resolve anything.
            break
        }
    }
}

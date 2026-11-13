import XCTest
@testable import ProxyMaxxPluginSDK

// MARK: - Fixtures

func makeManifest(permissions: [PluginManifestPermission]) -> PluginManifest {
    PluginManifest(
        id: "com.example.test-plugin",
        name: "Test Plugin",
        version: "1.0.0",
        sdkVersion: "^1.0.0",
        permissions: permissions
    )
}

func makeManifest(ids: [String]) -> PluginManifest {
    makeManifest(permissions: ids.map {
        PluginManifestPermission(id: $0, required: true, reason: "Testing \($0).")
    })
}

func makePermission(id: String, required: Bool = true, reason: String = "") -> PluginManifestPermission {
    PluginManifestPermission(id: id, required: required, reason: reason)
}

func manifestJSONString(ids: [String]) -> String {
    let permissions = ids.map { id in
        """
        {"id":"\(id)","required":true,"reason":"Testing \(id)."}
        """
    }.joined(separator: ",")
    return """
    {
      "id": "com.example.test-plugin",
      "name": "Test Plugin",
      "version": "1.0.0",
      "sdkVersion": "^1.0.0",
      "permissions": [\(permissions)]
    }
    """
}

// MARK: - Spy bridge (manager-level tests)

final class SpyBridge: PermissionHostBridge, @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [String] = []

    var requestHandler: ((String) async throws -> PermissionStatus)?
    var requestAllHandler: (([String]) async throws -> [String: PermissionStatus])?
    var checkHandler: ((String) async throws -> PermissionStatus)?
    var checkAllHandler: (([String]) async throws -> [String: PermissionStatus])?

    var recordedOperations: [String] {
        lock.lock()
        defer { lock.unlock() }
        return operations
    }

    private func record(_ operation: String) {
        lock.lock()
        operations.append(operation)
        lock.unlock()
    }

    func request(_ permissionId: String) async throws -> PermissionStatus {
        record("request")
        return try await requestHandler?(permissionId) ?? .granted
    }

    func requestAll(_ permissionIds: [String]) async throws -> [String: PermissionStatus] {
        record("requestAll")
        return try await requestAllHandler?(permissionIds) ?? [:]
    }

    func check(_ permissionId: String) async throws -> PermissionStatus {
        record("check")
        return try await checkHandler?(permissionId) ?? .granted
    }

    func checkAll(_ permissionIds: [String]) async throws -> [String: PermissionStatus] {
        record("checkAll")
        return try await checkAllHandler?(permissionIds) ?? [:]
    }
}

// MARK: - Scripted line source (bridge-level tests)

/// In-memory host channel. Enqueued lines are delivered in order; a source with
/// nothing enqueued blocks its reader (a `nil` enqueues end of channel).
final class ScriptedLineSource: LineSource, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [String?] = []
    private var waiters: [CheckedContinuation<String?, Never>] = []

    func enqueue(_ line: String?) {
        lock.lock()
        if let waiter = waiters.first {
            waiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: line)
        } else {
            queue.append(line)
            lock.unlock()
        }
    }

    func readLine() async throws -> String? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !queue.isEmpty {
                let item = queue.removeFirst()
                lock.unlock()
                continuation.resume(returning: item)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

// MARK: - Helpers

func encodedLine(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(data: data, encoding: .utf8)!
}

func statusReply(requestId: String, _ status: PermissionStatus) -> String {
    encodedLine([
        "kind": "permission.status",
        "requestId": requestId,
        "status": status.wireString,
    ])
}

func statusesReply(requestId: String, _ statuses: [String: PermissionStatus]) -> String {
    encodedLine([
        "kind": "permission.statuses",
        "requestId": requestId,
        "statuses": Dictionary(uniqueKeysWithValues: statuses.map { ($0.key, $0.value.wireString) }),
    ])
}

func cancelledReply(requestId: String) -> String {
    encodedLine(["kind": "permission.cancelled", "requestId": requestId])
}

/// Waits until `condition` holds, failing the test on timeout.
func pollUntil(
    timeout: TimeInterval = 2,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            XCTFail("Condition not met within \(timeout)s", file: file, line: line)
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// Extracts the request id of the first line with the given kind.
func firstRequestId(ofKind kind: String, in lines: [[String: Any]]) -> String? {
    lines.first { ($0["kind"] as? String) == kind }?["requestId"] as? String
}

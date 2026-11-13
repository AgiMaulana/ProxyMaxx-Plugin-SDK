import Foundation

/// The transport between the SDK and ProxyMaxx. The default implementation,
/// `JSONLinesBridge`, speaks protocol v1 (JSON-lines over stdin/stdout, see
/// `Docs/PROTOCOL.md`). Tests and embedders may supply their own bridge.
///
/// The bridge performs no manifest validation and keeps no state: it forwards
/// raw identifiers and returns raw statuses.
public protocol PermissionHostBridge: Sendable {
    /// Requests authorization for one permission. May display the host consent UI.
    func request(_ permissionId: String) async throws -> PermissionStatus

    /// Requests authorization for several permissions in one batch operation.
    /// Individual decisions are preserved; one denial does not affect others.
    func requestAll(_ permissionIds: [String]) async throws -> [String: PermissionStatus]

    /// Returns the current status of one permission without any UI.
    func check(_ permissionId: String) async throws -> PermissionStatus

    /// Returns the current status of the given permissions in one batch operation.
    func checkAll(_ permissionIds: [String]) async throws -> [String: PermissionStatus]
}

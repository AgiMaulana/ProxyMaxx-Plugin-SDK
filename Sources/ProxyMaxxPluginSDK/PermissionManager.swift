import Foundation

/// The public permission API for plugins (spec §5).
///
/// Every call validates permission identifiers against the plugin manifest
/// locally first, then delegates to the host bridge. The SDK keeps no state:
/// statuses are never cached, and grant/revoke remain host-owned.
///
/// A completed `request`/`requestAll` never surfaces `notRequested`; an
/// unverifiable host reply fails closed with `hostUnavailable`. Consent
/// dismissal propagates as `CancellationError`.
public actor PermissionManager {
    private let bridge: any PermissionHostBridge
    private let declaredIds: Set<String>
    private let manifestOrderIds: [String]

    /// Manager over an explicit bridge and manifest. Used by tests and
    /// embedders. The manifest is validated with the same rules as
    /// `ManifestLoader` (spec SDK-01): invalid manifests are rejected before
    /// any host communication can occur.
    public init(bridge: any PermissionHostBridge, manifest: PluginManifest) throws {
        try ManifestValidation.validate(manifest)
        self.bridge = bridge
        self.declaredIds = Set(manifest.permissionIds)
        self.manifestOrderIds = manifest.permissionIds
    }

    /// Default manager for a host-spawned plugin: loads `manifest.json` from
    /// `PROXYMAXX_PLUGIN_DIR` and uses the JSON-lines stdin/stdout bridge.
    public init() throws {
        let manifest = try ManifestLoader.standard.load()
        try self.init(bridge: JSONLinesBridge(), manifest: manifest)
    }

    /// Requests authorization for one declared permission (spec §5.1).
    public func request(_ permissionId: String) async throws -> PermissionStatus {
        guard declaredIds.contains(permissionId) else {
            throw PermissionError.notDeclared(permissionId: permissionId)
        }
        let status = try await bridge.request(permissionId)
        guard status != .notRequested else {
            // Spec §6: a completed request must not surface NOT_REQUESTED.
            throw PermissionError.hostUnavailable
        }
        return status
    }

    /// Requests authorization for several declared permissions in one batch
    /// operation (spec §5.2). Input is fully validated before the host is
    /// contacted; no partial request is initiated on invalid input.
    public func requestAll(_ permissionIds: [String]) async throws -> [String: PermissionStatus] {
        try validateBatchInput(permissionIds)
        let statuses = try await bridge.requestAll(permissionIds)
        var result: [String: PermissionStatus] = [:]
        for permissionId in permissionIds {
            guard let status = statuses[permissionId] else {
                // The batch reply must cover every requested permission.
                throw PermissionError.hostUnavailable
            }
            guard status != .notRequested else {
                // A consent-bearing batch must resolve every entry to a decision.
                throw PermissionError.hostUnavailable
            }
            result[permissionId] = status
        }
        return result
    }

    /// Returns the current status of one declared permission without any UI
    /// (spec §5.3).
    public func check(_ permissionId: String) async throws -> PermissionStatus {
        guard declaredIds.contains(permissionId) else {
            throw PermissionError.notDeclared(permissionId: permissionId)
        }
        return try await bridge.check(permissionId)
    }

    /// Returns the current status of every declared permission (spec §5.4).
    /// An empty manifest returns an empty map without contacting the host.
    public func checkAll() async throws -> [String: PermissionStatus] {
        guard !manifestOrderIds.isEmpty else { return [:] }
        let statuses = try await bridge.checkAll(manifestOrderIds)
        var result: [String: PermissionStatus] = [:]
        for permissionId in manifestOrderIds {
            guard let status = statuses[permissionId] else {
                // The reply must cover every declared permission.
                throw PermissionError.hostUnavailable
            }
            result[permissionId] = status
        }
        return result
    }

    // MARK: Internals

    private func validateBatchInput(_ permissionIds: [String]) throws {
        guard !permissionIds.isEmpty else {
            throw PermissionError.invalidRequest("permissionIds must not be empty.")
        }
        guard Set(permissionIds).count == permissionIds.count else {
            throw PermissionError.invalidRequest("permissionIds must not contain duplicates.")
        }
        for permissionId in permissionIds {
            guard declaredIds.contains(permissionId) else {
                throw PermissionError.notDeclared(permissionId: permissionId)
            }
        }
    }
}

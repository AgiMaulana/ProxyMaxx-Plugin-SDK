import Foundation

/// One permission declared in the plugin manifest.
public struct PluginManifestPermission: Codable, Sendable, Equatable {
    /// Stable permission identifier, for example `local-map.read`.
    public let id: String
    /// Communicates the plugin's functional dependency. Does not force the user
    /// to grant the permission.
    public let required: Bool
    /// Displayed by ProxyMaxx during consent.
    public let reason: String

    public init(id: String, required: Bool, reason: String) {
        self.id = id
        self.required = required
        self.reason = reason
    }
}

/// Minimal decode of the plugin's `manifest.json` covering the fields the SDK
/// needs. The host validates the full manifest during package installation; the
/// SDK reads only the declared permission set for local validation.
public struct PluginManifest: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let version: String
    public let sdkVersion: String
    public let permissions: [PluginManifestPermission]

    public init(
        id: String,
        name: String,
        version: String,
        sdkVersion: String,
        permissions: [PluginManifestPermission]
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.sdkVersion = sdkVersion
        self.permissions = permissions
    }

    /// Declared permission identifiers in manifest order.
    public var permissionIds: [String] {
        permissions.map(\.id)
    }
}

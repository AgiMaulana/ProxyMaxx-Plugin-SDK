import Foundation

/// Typed permission errors. Plugins should branch on these cases rather than
/// parsing error message strings.
public enum PermissionError: Error, Sendable, Equatable {
    /// The permission is not declared in the plugin manifest. Thrown locally by
    /// the SDK before the host is contacted; the host revalidates independently.
    case notDeclared(permissionId: String)

    /// Exception representation of an `unavailable` status, for protected APIs
    /// that need to surface an unsupported capability as an error.
    case unsupported(permissionId: String)

    /// A protected operation was executed without a granted permission. Reserved
    /// for the future Local Override API layer.
    case notGranted(permissionId: String)

    /// The host channel is unavailable, closed, or returned a reply that could
    /// not be verified. The SDK fails closed on every unverifiable situation.
    case hostUnavailable

    /// The SDK call itself is invalid (for example an empty or duplicate batch
    /// input). Thrown before any host communication starts.
    case invalidRequest(String)

    /// The plugin manifest could not be loaded or is malformed.
    case invalidManifest(String)
}

extension PermissionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notDeclared(let id):
            return "Permission '\(id)' is not declared in the plugin manifest."
        case .unsupported(let id):
            return "Permission '\(id)' is unsupported in this host environment."
        case .notGranted(let id):
            return "Permission '\(id)' has not been granted."
        case .hostUnavailable:
            return "The ProxyMaxx host permission channel is unavailable."
        case .invalidRequest(let reason):
            return "Invalid permission request: \(reason)"
        case .invalidManifest(let reason):
            return "Invalid plugin manifest: \(reason)"
        }
    }
}

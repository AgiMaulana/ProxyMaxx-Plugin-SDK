import Foundation

/// The current state of one permission, as resolved by ProxyMaxx.
///
/// `GRANTED` is the only status that authorizes a protected operation. The SDK
/// never treats `NOT_REQUESTED`, `DENIED`, or `UNAVAILABLE` as granted, and it
/// never caches statuses: every query resolves against the host's current state.
public enum PermissionStatus: String, Sendable {
    /// The user has granted the permission.
    case granted
    /// The user has explicitly denied the permission.
    case denied
    /// No user decision has been made yet.
    case notRequested
    /// The permission is unsupported or unavailable in the current host environment.
    case unavailable

    /// Wire representation sent by the host (uppercase, stable across versions).
    public var wireString: String {
        switch self {
        case .granted: return "GRANTED"
        case .denied: return "DENIED"
        case .notRequested: return "NOT_REQUESTED"
        case .unavailable: return "UNAVAILABLE"
        }
    }

    /// Decodes a host-supplied status string. Unknown values return `nil` so
    /// callers can fail closed instead of guessing.
    public init?(wireString: String) {
        switch wireString {
        case "GRANTED": self = .granted
        case "DENIED": self = .denied
        case "NOT_REQUESTED": self = .notRequested
        case "UNAVAILABLE": self = .unavailable
        default: return nil
        }
    }
}

extension PermissionStatus: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let status = PermissionStatus(wireString: raw) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown permission status: \(raw)"
                )
            )
        }
        self = status
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireString)
    }
}

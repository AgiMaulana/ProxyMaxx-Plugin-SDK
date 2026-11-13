import Foundation

/// Shared manifest validation applied on every SDK initialization path, so
/// `ManifestLoader.load()` and `PermissionManager.init(bridge:manifest:)`
/// reject the same malformed manifests.
///
/// The SDK validates only the fields it needs and does not invent a separate
/// identifier grammar: checks mirror the host's minimal rules (non-blank, no
/// whitespace or control characters, unique). Full package validation,
/// semantic-version compatibility, and permission registry validation remain
/// host responsibilities.
enum ManifestValidation {
    /// Scalars that make an identifier invalid: whitespace, newlines, and
    /// control/format/ignorable characters.
    private static let forbiddenScalars: CharacterSet = .whitespacesAndNewlines
        .union(.controlCharacters)
        .union(.illegalCharacters)

    static func validate(_ manifest: PluginManifest) throws {
        guard !manifest.id.isEmpty,
              manifest.id.unicodeScalars.allSatisfy({ !forbiddenScalars.contains($0) }) else {
            throw PermissionError.invalidManifest("Plugin id must not be blank or contain whitespace or control characters.")
        }

        var seen = Set<String>()
        for permission in manifest.permissions {
            guard !permission.id.isEmpty,
                  permission.id.unicodeScalars.allSatisfy({ !forbiddenScalars.contains($0) }) else {
                throw PermissionError.invalidManifest(
                    "Permission identifier '\(permission.id)' is blank or contains whitespace or control characters."
                )
            }
            guard seen.insert(permission.id).inserted else {
                throw PermissionError.invalidManifest("Duplicate permission identifier '\(permission.id)'.")
            }
        }
    }
}

import Foundation

/// Loads the plugin's `manifest.json` from `PROXYMAXX_PLUGIN_DIR`, the directory
/// the host runner sets when spawning the plugin.
///
/// Environment and filesystem access are injected so tests and embedders can
/// supply their own sources without touching the process environment.
public struct ManifestLoader: Sendable {
    public var environment: @Sendable (String) -> String?
    public var fileReader: @Sendable (String) throws -> Data

    public init(
        environment: @escaping @Sendable (String) -> String?,
        fileReader: @escaping @Sendable (String) throws -> Data
    ) {
        self.environment = environment
        self.fileReader = fileReader
    }

    /// The loader used by the default `PermissionManager` convenience init.
    public static let standard = ManifestLoader(
        environment: { key in ProcessInfo.processInfo.environment[key] },
        fileReader: { path in try Data(contentsOf: URL(fileURLWithPath: path)) }
    )

    /// Loads and validates the manifest. Throws `PermissionError.invalidManifest`
    /// when the directory, file, or contents are unusable, or when the plugin id
    /// or declared permission identifiers are blank, malformed, or duplicated.
    public func load() throws -> PluginManifest {
        guard let directory = environment("PROXYMAXX_PLUGIN_DIR"), !directory.isEmpty else {
            throw PermissionError.invalidManifest("PROXYMAXX_PLUGIN_DIR is not set.")
        }

        let manifestPath = URL(fileURLWithPath: directory)
            .appendingPathComponent("manifest.json", isDirectory: false).path
        let data: Data
        do {
            data = try fileReader(manifestPath)
        } catch {
            throw PermissionError.invalidManifest("Cannot read \(manifestPath): \(error.localizedDescription)")
        }

        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch {
            throw PermissionError.invalidManifest("Cannot decode manifest.json: \(error.localizedDescription)")
        }

        try ManifestValidation.validate(manifest)
        return manifest
    }
}

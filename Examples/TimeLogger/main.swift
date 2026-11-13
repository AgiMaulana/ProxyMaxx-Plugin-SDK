import Foundation
import ProxyMaxxPluginSDK

// Minimal example plugin: requests a declared permission, handles every
// outcome, and writes diagnostics to stderr. Stdout belongs to the SDK
// (protocol channel); never write to it directly.

func log(_ message: String) {
    FileHandle.standardError.write(Data("[TimeLogger] \(message)\n".utf8))
}

do {
    let permissions = try PermissionManager()

    switch try await permissions.request("local-map.read") {
    case .granted:
        log("Permission granted. Time Logger can read Local Override rules.")
        // Real logic would use the protected Local Override API here.

    case .denied:
        log("Permission denied. Rule logging stays disabled until the user "
            + "approves it in ProxyMaxx's permission management UI.")

    case .unavailable:
        log("Local Override capability is unavailable in this host environment.")

    case .notRequested:
        // A completed request never produces this status; the branch exists
        // only for switch exhaustiveness.
        break
    }
} catch is CancellationError {
    log("Consent was dismissed. No decision was recorded; the permission "
        + "remains NOT_REQUESTED.")
} catch PermissionError.notDeclared(let id) {
    log("Manifest error: '\(id)' is not declared in manifest.json.")
} catch PermissionError.hostUnavailable {
    log("The ProxyMaxx host permission channel is unavailable.")
} catch {
    log("Unexpected error: \(error)")
}

# ProxyMaxx Plugin SDK

Swift SDK for ProxyMaxx plugins. Provides the permission API plugins use to declare,
request, and check capabilities exposed by the ProxyMaxx host.

The SDK is an interface, not a security boundary. ProxyMaxx (the host) owns plugin
identity, manifest validation, consent, permission storage, and enforcement. The SDK
never stores permission decisions and never exposes a way to grant or revoke them.

## Documentation

- [Quick Start](Docs/QUICKSTART.md) — dependency, manifest, packaging, install
- [API Reference](Docs/API.md) — `PermissionManager`, statuses, errors, cancellation
- [Protocol v1](Docs/PROTOCOL.md) — wire contract, including host implementation status
- [Compatibility](Docs/COMPATIBILITY.md) — versioning and host compatibility matrix
- [Example plugin](Examples/TimeLogger) — minimal runnable plugin

## Usage

```swift
import ProxyMaxxPluginSDK

let permissions = PermissionManager()

switch try await permissions.request("local-map.create") {
case .granted:
    // create a Local Override rule through the protected API
    break
case .denied:
    // explain the feature is unavailable
    break
case .notRequested:
    // not produced by a completed request
    break
case .unavailable:
    // capability unsupported in this host environment
    break
}
```

- `request(_:)` / `requestAll(_:)` may display the host's native consent UI.
- `check(_:)` / `checkAll()` return the current status without any UI.
- Undeclared permissions (not present in the plugin manifest) throw
  `PermissionError.notDeclared` before the host is contacted.
- Dismissing the host consent UI surfaces as `CancellationError`. No decision is
  recorded and the permission stays `NOT_REQUESTED`.

The manager validates every permission identifier against the plugin's own
`manifest.json` (loaded from `PROXYMAXX_PLUGIN_DIR`, the directory the host runner
sets when spawning the plugin). The host revalidates everything; SDK-side checks are
for fast, predictable failure only.

## Transport

Plugins communicate with ProxyMaxx over JSON-lines on stdin/stdout (protocol v1,
see [Docs/PROTOCOL.md](Docs/PROTOCOL.md)).

**Stdout discipline:** stdout is the SDK's control channel to the host. Plugin
logging must go to stderr; writing arbitrary data to stdout corrupts the protocol
and the host terminates the plugin on malformed lines.

## Building

```sh
swift build
swift test
```

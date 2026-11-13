# Permission API Reference

The SDK's entire developer-facing surface. ProxyMaxx owns authorization: the
SDK never stores decisions, never caches statuses, and never grants anything.

## PermissionManager

Created once per plugin process. The default initializer loads
`manifest.json` from `PROXYMAXX_PLUGIN_DIR` and communicates over
stdin/stdout (Protocol v1):

```swift
let permissions = try PermissionManager()
```

Throws `PermissionError.invalidManifest` when the manifest is missing,
unreadable, or malformed (blank/duplicate permission identifiers, blank
plugin id).

### request(_:)

```swift
func request(_ permissionId: String) async throws -> PermissionStatus
```

Asks ProxyMaxx to obtain authorization. Shows the host's native consent UI
only when no decision exists yet:

| Existing state | Behavior |
|---|---|
| `GRANTED` | Returns `.granted`, no UI |
| `DENIED` | Returns `.denied`, no UI — the user changes this in ProxyMaxx's permission management UI |
| `NOT_REQUESTED` | Shows consent UI; resolves to a decision or cancellation |
| `UNAVAILABLE` | Returns `.unavailable` |
| Undeclared | Throws `notDeclared` before any host communication |
| Host channel unusable | Throws `hostUnavailable` |

User dismisses the consent sheet → `CancellationError`. No decision is
recorded; the permission stays `NOT_REQUESTED`.

### requestAll(_:)

```swift
func requestAll(_ permissionIds: [String]) async throws -> [String: PermissionStatus]
```

One batch operation; the host may group consent, but every permission keeps
an independent decision. Input is fully validated first: empty list or
duplicates → `invalidRequest`; any undeclared id → `notDeclared`. Invalid
input never initiates a partial request. The reply must cover every requested
id; gaps fail closed with `hostUnavailable`.

### check(_:)

```swift
func check(_ permissionId: String) async throws -> PermissionStatus
```

Current status, no UI. `notRequested` is a valid result here — use it to
decide whether to request at all.

### checkAll()

```swift
func checkAll() async throws -> [String: PermissionStatus]
```

Status of every declared permission in one batch operation. An empty manifest
returns `[:]` without contacting the host. Results never include other
plugins' decisions.

## PermissionStatus

| Status | Meaning |
|---|---|
| `.granted` | User granted. The **only** status that authorizes a protected operation |
| `.denied` | User explicitly denied |
| `.notRequested` | No user decision yet |
| `.unavailable` | Unsupported or unavailable in the current host environment |

## PermissionError

| Case | When |
|---|---|
| `notDeclared(permissionId:)` | Id not in the plugin manifest (thrown locally, no host round-trip) |
| `unsupported(permissionId:)` | Exception form of `.unavailable` for protected APIs |
| `notGranted(permissionId:)` | Reserved for protected Local Override APIs |
| `hostUnavailable` | Channel closed/malformed/unverifiable reply — always fail closed |
| `invalidRequest(String)` | Empty or duplicate batch input |
| `invalidManifest(String)` | Manifest missing, unreadable, or invalid |

## Error-handling patterns

```swift
// Denied: explain, disable the feature, never retry the prompt.
case .denied:
    showFeatureDisabled("Response mapping requires your approval in ProxyMaxx.")

// Unavailable: the capability does not exist in this host version.
case .unavailable:
    showUnsupportedMessage()

// Not declared: developer error, not a runtime condition.
} catch PermissionError.notDeclared(let id) {
    fatalError("Manifest bug: '\(id)' is not declared")
}

// Consent dismissed: nothing was decided; the user may request again later.
} catch is CancellationError {
    logToStderr("consent dismissed")
}

// Host unavailable: fail closed, surface a transport error.
} catch PermissionError.hostUnavailable {
    logToStderr("ProxyMaxx host channel is down")
}
```

## Revocation semantics

Revocation (via ProxyMaxx's permission management UI) resets a permission to
`NOT_REQUESTED`: `check()` reflects it immediately, subsequent `request()`
may show consent again, and protected operations are denied until re-granted.
Revocation is not a denial. The SDK caches nothing, so no stale grant can
survive a revoke.

## Versioning

See [COMPATIBILITY.md](COMPATIBILITY.md). The wire protocol (Protocol v1,
[PROTOCOL.md](PROTOCOL.md)) is versioned independently of the SDK package
version.

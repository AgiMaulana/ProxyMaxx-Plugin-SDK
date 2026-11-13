# AGENTS.md — ProxyMaxx Plugin SDK

Swift SDK for ProxyMaxx plugins. Exposes the permission API plugins use to
declare, request, and check capabilities. The SDK is an interface, not a
security boundary: ProxyMaxx (the host) owns plugin identity, manifest
validation, consent, permission storage, and enforcement. The SDK keeps no
permission state and never exposes grant/revoke operations.

The companion host project lives at `../ProxyMaxx` (PluginKit host plan:
`.zcode/plans/` inside that repo). The permission API specification and its
revisions are the source of truth for behavior; `Docs/PROTOCOL.md` is the
source of truth for the wire contract.

## Layout

```
Package.swift                      swift-tools 5.10, macOS 14, zero dependencies
Sources/ProxyMaxxPluginSDK/
  PermissionStatus.swift           GRANTED/DENIED/NOT_REQUESTED/UNAVAILABLE (uppercase wire strings)
  PermissionError.swift            typed errors; fail closed on every unverifiable situation
  PluginManifest.swift             minimal manifest.json decode (id, name, version, sdkVersion, permissions)
  ManifestLoader.swift             loads manifest from PROXYMAXX_PLUGIN_DIR; env/file access injected
  PermissionManager.swift          public actor: request/requestAll/check/checkAll + local validation
  PermissionHostBridge.swift       transport protocol (tests/embedders may substitute)
  JSONLinesBridge.swift            protocol v1 implementation over stdin/stdout
  JSONLines.swift                  codec + FileHandle line source/sink
  PendingRequestTable.swift        requestId → continuation correlation; cancellation-safe
Docs/PROTOCOL.md                   wire contract v1 (message table, host/SDK obligations)
Tests/ProxyMaxxPluginSDKTests/     XCTest; manager-level (SpyBridge) + wire-level (ScriptedLineSource)
```

## Commands

```sh
swift build     # library + tests
swift test      # XCTest only; all tests must stay green
```

No external dependencies. Do not add any without strong justification — the SDK
is embedded in every plugin process.

## Non-negotiable behavior rules

These come from the permission spec (§5–§10). Changes here require a spec
change first:

- **Local validation before host contact.** Undeclared permission ids throw
  `notDeclared` without a round-trip; invalid batch input (empty, duplicates,
  any undeclared) throws before any partial request is initiated.
- **Fail closed.** Unknown status strings, batch replies missing requested ids,
  malformed lines, closed channel, `NOT_REQUESTED` surfacing from a completed
  request → all fail with `hostUnavailable`. Never guess at an unverifiable
  reply.
- **No state.** Statuses are never cached; every call resolves current host
  state (revocation must be observable immediately).
- **Cancellation is cancellation.** Task cancellation sends `permission.cancel`
  and throws `CancellationError`; host `permission.cancelled` throws
  `CancellationError`. Never convert cancellation to a status.
- **A completed `request`/`requestAll` never returns `notRequested`.**

## Transport rules

- Plugin stdout is the protocol channel. Plugin logging goes to stderr.
- JSON-lines, one object per line, 1 MiB bounded, unknown message kinds
  ignored, unknown request kinds must be tolerated by the host (forward
  compatibility).
- See `Docs/PROTOCOL.md` for the full message table and the deviations from
  the host PluginRunner plan (requestId, batch, check, cancel messages) that
  the host side must adopt when PluginKit is implemented.

## Conventions

- Swift 5.10 language mode, structured concurrency throughout. Lock-based
  synchronization (not actors) for structures touched from cancellation
  handlers; actors for the public API surface.
- Public API is minimal: only types a plugin developer needs
  (`PermissionManager`, `PermissionStatus`, `PermissionError`,
  `PluginManifest*`, `PermissionHostBridge`). Transport internals stay
  `internal`.
- Tests: XCTest, `@testable import`. Manager-level tests use `SpyBridge`;
  wire-level tests use `ScriptedLineSource` + `CapturingLineSink`. No process
  environment access in tests (inject everything).
- Changing `PermissionStatus.wireString` values or message `kind` strings is a
  protocol break — both sides (SDK + host PluginRunner) must move together.

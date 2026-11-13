# Versioning & Compatibility

## SDK package versioning

The SDK follows [Semantic Versioning](https://semver.org/). Releases are
tagged `vX.Y.Z` on GitHub with release notes.

- **Major** — breaking change to the public API (`PermissionManager`,
  `PermissionStatus`, `PermissionError`, `PluginManifest*`,
  `PermissionHostBridge`) or to protocol v1 message shapes.
- **Minor** — additive public API, new internal hardening, documentation.
- **Patch** — fixes with no API or wire changes.

The wire protocol is documented separately in
[PROTOCOL.md](PROTOCOL.md) and versioned independently of the package
version: matching package versions do not imply matching protocol versions.
Protocol v1 is the current contract; a protocol version negotiation mechanism
will be introduced only if a future protocol version actually requires one.

## Manifest `sdkVersion` semantics

Plugins declare an SDK compatibility range in `manifest.json`
(`"sdkVersion": "^0.1.0"`). ProxyMaxx validates that range at install time;
the SDK does not enforce it. Range syntax and validation rules are owned by
the host and documented in `ProxyMaxx/docs/plugin-store-phase1.md`.

## Host compatibility matrix

| SDK version | Protocol | Host support |
|---|---|---|
| 0.1.x | v1 | Pending — ProxyMaxx PR #49 must adopt protocol v1 (see the "Host implementation status" section of [PROTOCOL.md](PROTOCOL.md)) |

Until the host adopts protocol v1 (requestId correlation, batch/check/cancel
messages, `permission.cancelled` for dismissal), SDK plugins running against
the PR #49 runner will not interoperate correctly. No compatibility adapter
exists or is planned: the host moves to the documented contract.

## Breaking-change policy

Public API breaks and wire-protocol breaks are called out separately in
release notes. A wire change requires a coordinated SDK + host release and a
protocol version bump (v1 → v2) with a negotiation decision at that time.

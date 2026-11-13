# ProxyMaxx Permission Bridge Protocol — v1

Wire contract between a plugin process (via the ProxyMaxx Plugin SDK) and the
ProxyMaxx host runner.

- Transport: JSON-lines. Exactly one JSON object per line, newline-terminated,
  UTF-8. Plugin → host on the plugin's **stdout**; host → plugin on the plugin's
  **stdin**.
- Bounded line length: 1 MiB. Malformed or oversized lines terminate the channel;
  every outstanding plugin request fails closed (`hostUnavailable`).
- Every request message carries a `requestId` (UUID string). Replies carry the
  same `requestId`. A reply with an unknown `requestId` is ignored.
- **Stdout discipline:** stdout is the protocol channel. Plugin logging must go
  to stderr. Arbitrary stdout data corrupts the protocol.

## Status values

`GRANTED`, `DENIED`, `NOT_REQUESTED`, `UNAVAILABLE` (exact uppercase strings).
Unknown status values fail closed.

- `GRANTED` is the only status that authorizes a protected operation.
- `DENIED` is a user decision; the host does not re-prompt for it.
- `NOT_REQUESTED` is the absence of a decision; valid for `check` replies.
- `UNAVAILABLE` is a host capability limitation.

## Messages: plugin → host (stdout)

| kind | Fields | Meaning |
|---|---|---|
| `permission.request` | `requestId`, `permissionId` | Request authorization; host may show consent UI |
| `permission.requestAll` | `requestId`, `permissionIds` (array) | Batch request; host may group consent, independent decisions required |
| `permission.check` | `requestId`, `permissionId` | Current status, no UI |
| `permission.checkAll` | `requestId`, `permissionIds` (array) | Batch check, no UI |
| `permission.cancel` | `requestId` | Plugin cancelled a pending request |

## Messages: host → plugin (stdin)

| kind | Fields | Meaning |
|---|---|---|
| `permission.status` | `requestId`, `status` | Reply to `request` or `check` |
| `permission.statuses` | `requestId`, `statuses` (object: permissionId → status) | Reply to batch messages; **every requested id must appear** |
| `permission.cancelled` | `requestId` | User dismissed/cancelled consent |
| `permission.error` | `requestId`, `error` | Unrecoverable host-side failure |

Unknown message kinds are ignored by the SDK. The host must ignore unknown
request kinds for forward compatibility.

## Contract obligations

**Host must:**

- Identify the requesting plugin from the host-managed process context, never
  from plugin-supplied input, and revalidate manifest declarations.
- Signal consent dismissal/cancellation with `permission.cancelled`. **Never**
  substitute `DENIED` or `NOT_REQUESTED` for cancellation (spec §7.2).
- For batch requests, preserve independent decisions and report one status per
  requested permission id.
- Never expose an operation that grants permissions programmatically.
- Treat a cancelled request as leaving no persisted decision.

**SDK must:**

- Validate identifiers against the plugin manifest before contacting the host
  (host revalidates as defense in depth).
- Never cache permission statuses; every query resolves current host state.
- Fail closed on any unverifiable reply (unknown status string, missing ids in
  a batch reply, malformed line, closed channel).
- Propagate cancellation unchanged: task cancellation sends
  `permission.cancel` and throws `CancellationError`; a `permission.cancelled`
  reply throws `CancellationError` (never converted to a status).

## Deviations from the host runner plan

The PluginKit host plan (`ProxyMaxx/.zcode/plans/plan-sess_73b7107a-…md`) defines
`permission.request` → `permission.status` without correlation ids. Protocol v1
extends that contract with: `requestId` correlation, batch messages
(`permission.requestAll`/`permission.checkAll`/`permission.statuses`), check
messages, and cancellation (`permission.cancel`/`permission.cancelled`). The host
`PluginRunner.swift` must adopt these when PluginKit is implemented.

## Example exchange

```
plugin → host: {"kind":"permission.check","requestId":"A1","permissionId":"local-map.read"}
host → plugin: {"kind":"permission.status","requestId":"A1","status":"NOT_REQUESTED"}

plugin → host: {"kind":"permission.request","requestId":"A2","permissionId":"local-map.read"}
host → plugin: {"kind":"permission.cancelled","requestId":"A2"}     // user dismissed consent

plugin → host: {"kind":"permission.requestAll","requestId":"A3","permissionIds":["local-map.read","local-map.create"]}
host → plugin: {"kind":"permission.statuses","requestId":"A3","statuses":{"local-map.read":"GRANTED","local-map.create":"DENIED"}}
```

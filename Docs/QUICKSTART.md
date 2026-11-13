# ProxyMaxx Plugin SDK — Quick Start

Build, package, and install a minimal ProxyMaxx plugin that requests a
permission. A complete working example lives at
[`Examples/TimeLogger/`](../Examples/TimeLogger).

## 1. Add the SDK dependency

In your plugin's `Package.swift`:

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TimeLogger",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/AgiMaulana/ProxyMaxx-Plugin-SDK.git", from: "0.1.0")
    ],
    targets: [
        .executableTarget(
            name: "TimeLogger",
            dependencies: [.product(name: "ProxyMaxxPluginSDK", package: "ProxyMaxx-Plugin-SDK")]
        )
    ]
)
```

## 2. Write the plugin manifest

`manifest.json` at the root of your plugin bundle. Field names and validation
rules are owned by ProxyMaxx (package validation happens at install time);
the SDK reads `permissions` for local validation.

```json
{
  "formatVersion": 1,
  "id": "com.example.timelogger",
  "name": "Time Logger",
  "version": "1.0.0",
  "description": "Logs the time of each Local Override rule read.",
  "author": "Example Developer",
  "sdkVersion": "^0.1.0",
  "permissions": [
    {
      "id": "local-map.read",
      "required": true,
      "reason": "Read existing response mapping rules to log their names."
    }
  ],
  "entryPoint": "TimeLogger"
}
```

Rules:

- Request only permissions you need. Unknown identifiers are rejected at
  install time; undeclared identifiers throw `notDeclared` at runtime.
- `required` communicates functional dependency — it does not force the user
  to grant.
- `reason` is shown by ProxyMaxx in the consent UI.

## 3. Use the SDK in your entry point

```swift
import Foundation
import ProxyMaxxPluginSDK

let permissions = try PermissionManager()

do {
    switch try await permissions.request("local-map.read") {
    case .granted:
        FileHandle.standardError.write(Data("permission granted\n".utf8))
    case .denied:
        FileHandle.standardError.write(Data("permission denied; feature disabled\n".utf8))
    case .unavailable:
        FileHandle.standardError.write(Data("capability unavailable in this host\n".utf8))
    case .notRequested:
        // Never produced by a completed request.
        break
    }
} catch is CancellationError {
    FileHandle.standardError.write(Data("consent dismissed; nothing was recorded\n".utf8))
} catch {
    FileHandle.standardError.write(Data("host error: \(error)\n".utf8))
}
```

See [API.md](API.md) for the full reference and error-handling patterns.

## 4. Build and package

```sh
swift build -c release
# Zip the release executable as TimeLogger.pxplugin with this layout:
#   manifest.json
#   TimeLogger  (the entryPoint executable)
zip TimeLogger.pxplugin manifest.json TimeLogger
```

Install it through ProxyMaxx: **Plugin Store → Install from File**. Install
grants nothing — permissions are granted through consent when the plugin
requests them.

## 5. Runtime expectations

When ProxyMaxx runs your plugin, the host process:

- Sets `PROXYMAXX_PLUGIN_DIR` (installed plugin directory), plus
  `PROXYMAXX_PLUGIN_ID`, `PROXYMAXX_SDK_VERSION`, `PROXYMAXX_SUPPORT_DIR`.
- Speaks [Protocol v1](PROTOCOL.md) JSON-lines with your process: the SDK's
  requests go to **stdout**, host replies arrive on **stdin**.
- Terminates the plugin on malformed protocol traffic.

**Stdout discipline:** stdout is the SDK's control channel. All plugin logging
must go to **stderr** (`FileHandle.standardError`). Writing anything else to
stdout corrupts the protocol.

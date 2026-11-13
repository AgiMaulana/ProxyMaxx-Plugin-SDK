// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ProxyMaxxSDK",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ProxyMaxxPluginSDK",
            targets: ["ProxyMaxxPluginSDK"]
        )
    ],
    targets: [
        .target(
            name: "ProxyMaxxPluginSDK"
        ),
        .executableTarget(
            name: "TimeLoggerExample",
            dependencies: ["ProxyMaxxPluginSDK"],
            path: "Examples/TimeLogger"
        ),
        .testTarget(
            name: "ProxyMaxxPluginSDKTests",
            dependencies: ["ProxyMaxxPluginSDK"]
        )
    ]
)

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
        .testTarget(
            name: "ProxyMaxxPluginSDKTests",
            dependencies: ["ProxyMaxxPluginSDK"]
        )
    ]
)

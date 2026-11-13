import XCTest
@testable import ProxyMaxxPluginSDK

final class ManifestTests: XCTestCase {
    private func makeLoader(
        directory: String?,
        fileReader: @escaping @Sendable (String) throws -> Data
    ) -> ManifestLoader {
        ManifestLoader(
            environment: { key in key == "PROXYMAXX_PLUGIN_DIR" ? directory : nil },
            fileReader: fileReader
        )
    }

    func testLoadsManifestFromPluginDirectory() throws {
        let loader = makeLoader(directory: "/tmp/plugins/example") { path in
            XCTAssertTrue(path.hasSuffix("/manifest.json"), "manifest path: \(path)")
            return Data(manifestJSONString(ids: ["local-map.read", "local-map.create"]).utf8)
        }

        let manifest = try loader.load()

        XCTAssertEqual(manifest.id, "com.example.test-plugin")
        XCTAssertEqual(manifest.permissionIds, ["local-map.read", "local-map.create"])
    }

    func testMissingPluginDirectoryThrowsInvalidManifest() {
        let loader = makeLoader(directory: nil) { _ in Data() }

        XCTAssertThrowsError(try loader.load()) { error in
            guard case PermissionError.invalidManifest = error else {
                return XCTFail("Expected invalidManifest, got \(error)")
            }
        }
    }

    func testUnreadableManifestThrowsInvalidManifest() throws {
        let loader = makeLoader(directory: "/tmp/plugins/example") { _ in
            throw NSError(domain: "test", code: 1)
        }

        XCTAssertThrowsError(try loader.load()) { error in
            guard case PermissionError.invalidManifest = error else {
                return XCTFail("Expected invalidManifest, got \(error)")
            }
        }
    }

    func testMalformedManifestThrowsInvalidManifest() throws {
        let loader = makeLoader(directory: "/tmp/plugins/example") { _ in
            Data("{ not json".utf8)
        }

        XCTAssertThrowsError(try loader.load()) { error in
            guard case PermissionError.invalidManifest = error else {
                return XCTFail("Expected invalidManifest, got \(error)")
            }
        }
    }

    func testBlankPermissionIdThrowsInvalidManifest() throws {
        let loader = makeLoader(directory: "/tmp/plugins/example") { _ in
            let json = """
            {
              "id": "com.example.test-plugin",
              "name": "Test Plugin",
              "version": "1.0.0",
              "sdkVersion": "^1.0.0",
              "permissions": [{"id": " ", "required": true, "reason": "x"}]
            }
            """
            return Data(json.utf8)
        }

        XCTAssertThrowsError(try loader.load()) { error in
            guard case PermissionError.invalidManifest = error else {
                return XCTFail("Expected invalidManifest, got \(error)")
            }
        }
    }

    func testDuplicatePermissionIdsThrowInvalidManifest() throws {
        let loader = makeLoader(directory: "/tmp/plugins/example") { _ in
            Data(manifestJSONString(ids: ["local-map.read", "local-map.read"]).utf8)
        }

        XCTAssertThrowsError(try loader.load()) { error in
            guard case PermissionError.invalidManifest = error else {
                return XCTFail("Expected invalidManifest, got \(error)")
            }
        }
    }

    func testDefaultManagerFailsWhenManifestUnavailable() throws {
        // The default init reads the real process environment. Without
        // PROXYMAXX_PLUGIN_DIR set (as in test processes), it must fail closed.
        guard ProcessInfo.processInfo.environment["PROXYMAXX_PLUGIN_DIR"] == nil else {
            throw XCTSkip("PROXYMAXX_PLUGIN_DIR is set in this environment")
        }
        XCTAssertThrowsError(try PermissionManager()) { error in
            guard case PermissionError.invalidManifest = error else {
                return XCTFail("Expected invalidManifest, got \(error)")
            }
        }
    }
}

extension ManifestTests {
    func testManagerInitRejectsDuplicatePermissionIdsWithoutHostContact() async throws {
        let bridge = SpyBridge()
        do {
            _ = try PermissionManager(
                bridge: bridge,
                manifest: makeManifest(ids: ["local-map.read", "local-map.read"])
            )
            XCTFail("Expected invalidManifest")
        } catch let error as PermissionError {
            guard case .invalidManifest = error else {
                return XCTFail("Expected invalidManifest, got \(error)")
            }
        }
        XCTAssertEqual(bridge.recordedOperations, [])
    }

    func testManagerInitRejectsPermissionIdWithWhitespace() async throws {
        let bridge = SpyBridge()
        do {
            _ = try PermissionManager(
                bridge: bridge,
                manifest: makeManifest(permissions: [makePermission(id: "local map.read")])
            )
            XCTFail("Expected invalidManifest")
        } catch let error as PermissionError {
            guard case .invalidManifest = error else {
                return XCTFail("Expected invalidManifest, got \(error)")
            }
        }
        XCTAssertEqual(bridge.recordedOperations, [])
    }

    func testManagerInitRejectsEmptyPluginId() async throws {
        let bridge = SpyBridge()
        do {
            _ = try PermissionManager(
                bridge: bridge,
                manifest: PluginManifest(
                    id: "",
                    name: "x",
                    version: "1.0.0",
                    sdkVersion: "^1.0.0",
                    permissions: [makePermission(id: "local-map.read")]
                )
            )
            XCTFail("Expected invalidManifest")
        } catch let error as PermissionError {
            guard case .invalidManifest = error else {
                return XCTFail("Expected invalidManifest, got \(error)")
            }
        }
        XCTAssertEqual(bridge.recordedOperations, [])
    }

    func testValidManifestBehavesIdenticallyOnBothInitializationPaths() async throws {
        // Injected path.
        let injectedBridge = SpyBridge()
        let injected = try PermissionManager(
            bridge: injectedBridge,
            manifest: makeManifest(ids: ["local-map.read"])
        )
        _ = try await injected.check("local-map.read")

        // Loader path: identical declared set via injected environment.
        let loader = ManifestLoader(
            environment: { _ in "/tmp/plugins/example" },
            fileReader: { _ in Data(manifestJSONString(ids: ["local-map.read"]).utf8) }
        )
        let loadedManifest = try loader.load()
        let loaderBridge = SpyBridge()
        let loaded = try PermissionManager(bridge: loaderBridge, manifest: loadedManifest)
        _ = try await loaded.check("local-map.read")

        XCTAssertEqual(injectedBridge.recordedOperations, loaderBridge.recordedOperations)
    }
}

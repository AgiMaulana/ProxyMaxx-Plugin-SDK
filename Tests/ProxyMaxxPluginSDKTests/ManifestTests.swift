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

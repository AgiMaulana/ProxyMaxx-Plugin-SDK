import XCTest
@testable import ProxyMaxxPluginSDK

final class CheckTests: XCTestCase {
    func testCheckMapsEveryStatusWithoutConsent() async throws {
        // Spec §5.3: check never displays consent UI; NOT_REQUESTED is valid here.
        let bridge = SpyBridge()
        let manager = try PermissionManager(bridge: bridge, manifest: makeManifest(ids: ["local-map.read"]))

        for expected in [PermissionStatus.granted, .denied, .notRequested, .unavailable] {
            bridge.checkHandler = { _ in expected }
            let status = try await manager.check("local-map.read")
            XCTAssertEqual(status, expected, "check should pass through \(expected)")
        }
        XCTAssertEqual(bridge.recordedOperations, ["check", "check", "check", "check"])
    }

    func testCheckUndeclaredPermissionThrowsNotDeclaredWithoutHostContact() async throws {
        let bridge = SpyBridge()
        let manager = try PermissionManager(bridge: bridge, manifest: makeManifest(ids: ["local-map.read"]))

        do {
            _ = try await manager.check("filesystem.read")
            XCTFail("Expected notDeclared")
        } catch let error as PermissionError {
            XCTAssertEqual(error, .notDeclared(permissionId: "filesystem.read"))
        }
        XCTAssertEqual(bridge.recordedOperations, [])
    }

    func testCheckHostFailurePropagates() async throws {
        let bridge = SpyBridge()
        bridge.checkHandler = { _ in throw PermissionError.hostUnavailable }
        let manager = try PermissionManager(bridge: bridge, manifest: makeManifest(ids: ["local-map.read"]))

        do {
            _ = try await manager.check("local-map.read")
            XCTFail("Expected hostUnavailable")
        } catch let error as PermissionError {
            XCTAssertEqual(error, .hostUnavailable)
        }
    }

    func testCheckAllReturnsEveryDeclaredPermission() async throws {
        let bridge = SpyBridge()
        bridge.checkAllHandler = { ids in
            [
                ids[0]: .granted,
                ids[1]: .notRequested,
                ids[2]: .unavailable,
            ]
        }
        let manager = try PermissionManager(
            bridge: bridge,
            manifest: makeManifest(ids: ["local-map.read", "local-map.create", "local-map.delete"])
        )

        let statuses = try await manager.checkAll()

        XCTAssertEqual(statuses, [
            "local-map.read": .granted,
            "local-map.create": .notRequested,
            "local-map.delete": .unavailable,
        ])
        XCTAssertEqual(bridge.recordedOperations, ["checkAll"])
    }

    func testCheckAllWithEmptyManifestReturnsEmptyMapWithoutHostContact() async throws {
        // Spec §5.4: no permissions declared → empty map, no host call.
        let bridge = SpyBridge()
        let manager = try PermissionManager(bridge: bridge, manifest: makeManifest(ids: []))

        let statuses = try await manager.checkAll()

        XCTAssertTrue(statuses.isEmpty)
        XCTAssertEqual(bridge.recordedOperations, [])
    }

    func testCheckAllReplyMissingAnIdFailsClosed() async throws {
        let bridge = SpyBridge()
        bridge.checkAllHandler = { ids in [ids[0]: .granted] }
        let manager = try PermissionManager(
            bridge: bridge,
            manifest: makeManifest(ids: ["local-map.read", "local-map.create"])
        )

        do {
            _ = try await manager.checkAll()
            XCTFail("Expected hostUnavailable")
        } catch let error as PermissionError {
            XCTAssertEqual(error, .hostUnavailable)
        }
    }
}

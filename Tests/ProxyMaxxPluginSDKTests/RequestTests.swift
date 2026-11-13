import XCTest
@testable import ProxyMaxxPluginSDK

final class RequestTests: XCTestCase {
    func testDeclaredRequestReturnsHostStatus() async throws {
        let bridge = SpyBridge()
        bridge.requestHandler = { _ in .granted }
        let manager = PermissionManager(bridge: bridge, manifest: makeManifest(ids: ["local-map.read"]))

        let status = try await manager.request("local-map.read")

        XCTAssertEqual(status, .granted)
        XCTAssertEqual(bridge.recordedOperations, ["request"])
    }

    func testDeniedStatusPassesThrough() async throws {
        let bridge = SpyBridge()
        bridge.requestHandler = { _ in .denied }
        let manager = PermissionManager(bridge: bridge, manifest: makeManifest(ids: ["local-map.create"]))

        let status = try await manager.request("local-map.create")

        XCTAssertEqual(status, .denied)
    }

    func testUnavailableStatusPassesThrough() async throws {
        let bridge = SpyBridge()
        bridge.requestHandler = { _ in .unavailable }
        let manager = PermissionManager(bridge: bridge, manifest: makeManifest(ids: ["local-map.read"]))

        let status = try await manager.request("local-map.read")

        XCTAssertEqual(status, .unavailable)
    }

    func testUndeclaredRequestThrowsNotDeclaredWithoutHostContact() async throws {
        let bridge = SpyBridge()
        let manager = PermissionManager(
            bridge: bridge,
            manifest: makeManifest(ids: ["local-map.read", "local-map.create"])
        )

        do {
            _ = try await manager.request("filesystem.read")
            XCTFail("Expected notDeclared")
        } catch let error as PermissionError {
            XCTAssertEqual(error, .notDeclared(permissionId: "filesystem.read"))
        }
        // Spec §5.1: validation happens before contacting the host.
        XCTAssertEqual(bridge.recordedOperations, [])
    }

    func testRequestFailsClosedOnNotRequestedReply() async throws {
        // Spec §6: a completed request must not surface NOT_REQUESTED.
        let bridge = SpyBridge()
        bridge.requestHandler = { _ in .notRequested }
        let manager = PermissionManager(bridge: bridge, manifest: makeManifest(ids: ["local-map.read"]))

        do {
            _ = try await manager.request("local-map.read")
            XCTFail("Expected hostUnavailable")
        } catch let error as PermissionError {
            XCTAssertEqual(error, .hostUnavailable)
        }
    }

    func testHostFailurePropagates() async throws {
        let bridge = SpyBridge()
        bridge.requestHandler = { _ in throw PermissionError.hostUnavailable }
        let manager = PermissionManager(bridge: bridge, manifest: makeManifest(ids: ["local-map.read"]))

        do {
            _ = try await manager.request("local-map.read")
            XCTFail("Expected hostUnavailable")
        } catch let error as PermissionError {
            XCTAssertEqual(error, .hostUnavailable)
        }
    }

    func testRequestsAreNeverCached() async throws {
        var count = 0
        let bridge = SpyBridge()
        bridge.requestHandler = { _ in
            count += 1
            return count == 1 ? .denied : .granted
        }
        let manager = PermissionManager(bridge: bridge, manifest: makeManifest(ids: ["local-map.read"]))

        // Spec §10: the SDK keeps no state; the second call resolves host state again.
        let first = try await manager.request("local-map.read")
        let second = try await manager.request("local-map.read")

        XCTAssertEqual(first, .denied)
        XCTAssertEqual(second, .granted)
        XCTAssertEqual(bridge.recordedOperations, ["request", "request"])
    }
}

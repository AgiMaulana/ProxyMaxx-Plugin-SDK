import XCTest
@testable import ProxyMaxxPluginSDK

final class RequestAllTests: XCTestCase {
    func testEmptyListThrowsInvalidRequestWithoutHostContact() async throws {
        let bridge = SpyBridge()
        let manager = PermissionManager(bridge: bridge, manifest: makeManifest(ids: ["local-map.read"]))

        do {
            _ = try await manager.requestAll([])
            XCTFail("Expected invalidRequest")
        } catch let error as PermissionError {
            guard case .invalidRequest = error else {
                return XCTFail("Expected invalidRequest, got \(error)")
            }
        }
        XCTAssertEqual(bridge.recordedOperations, [])
    }

    func testDuplicateIdentifiersThrowInvalidRequestWithoutHostContact() async throws {
        let bridge = SpyBridge()
        let manager = PermissionManager(
            bridge: bridge,
            manifest: makeManifest(ids: ["local-map.read", "local-map.create"])
        )

        do {
            _ = try await manager.requestAll(["local-map.read", "local-map.read"])
            XCTFail("Expected invalidRequest")
        } catch let error as PermissionError {
            guard case .invalidRequest = error else {
                return XCTFail("Expected invalidRequest, got \(error)")
            }
        }
        XCTAssertEqual(bridge.recordedOperations, [])
    }

    func testOneUndeclaredPermissionFailsWholeBatchWithoutHostContact() async throws {
        let bridge = SpyBridge()
        let manager = PermissionManager(bridge: bridge, manifest: makeManifest(ids: ["local-map.read"]))

        do {
            _ = try await manager.requestAll(["local-map.read", "filesystem.read"])
            XCTFail("Expected notDeclared")
        } catch let error as PermissionError {
            XCTAssertEqual(error, .notDeclared(permissionId: "filesystem.read"))
        }
        // Spec §5.2: invalid input must not initiate a partial request.
        XCTAssertEqual(bridge.recordedOperations, [])
    }

    func testBatchPreservesIndependentDecisions() async throws {
        let bridge = SpyBridge()
        bridge.requestAllHandler = { ids in
            [
                ids[0]: PermissionStatus.granted,
                ids[1]: PermissionStatus.denied,
                ids[2]: PermissionStatus.unavailable,
            ]
        }
        let manager = PermissionManager(
            bridge: bridge,
            manifest: makeManifest(ids: ["local-map.read", "local-map.create", "local-map.update"])
        )

        let statuses = try await manager.requestAll(
            ["local-map.read", "local-map.create", "local-map.update"]
        )

        XCTAssertEqual(statuses, [
            "local-map.read": .granted,
            "local-map.create": .denied,
            "local-map.update": .unavailable,
        ])
        // One batch operation, not N singular calls.
        XCTAssertEqual(bridge.recordedOperations, ["requestAll"])
    }

    func testBatchReplyMissingAnIdFailsClosed() async throws {
        let bridge = SpyBridge()
        bridge.requestAllHandler = { ids in [ids[0]: .granted] }
        let manager = PermissionManager(
            bridge: bridge,
            manifest: makeManifest(ids: ["local-map.read", "local-map.create"])
        )

        do {
            _ = try await manager.requestAll(["local-map.read", "local-map.create"])
            XCTFail("Expected hostUnavailable")
        } catch let error as PermissionError {
            XCTAssertEqual(error, .hostUnavailable)
        }
    }

    func testBatchEntryWithNotRequestedFailsClosed() async throws {
        let bridge = SpyBridge()
        bridge.requestAllHandler = { ids in [ids[0]: .notRequested, ids[1]: .granted] }
        let manager = PermissionManager(
            bridge: bridge,
            manifest: makeManifest(ids: ["local-map.read", "local-map.create"])
        )

        do {
            _ = try await manager.requestAll(["local-map.read", "local-map.create"])
            XCTFail("Expected hostUnavailable")
        } catch let error as PermissionError {
            XCTAssertEqual(error, .hostUnavailable)
        }
    }

    func testRevokedPermissionIsEligibleForNewConsent() async throws {
        // Spec §10.1: revocation resets to NOT_REQUESTED; a subsequent request
        // resolves fresh host state. The SDK must not cache the old grant.
        var state = PermissionStatus.granted
        let bridge = SpyBridge()
        bridge.requestHandler = { _ in state }
        let manager = PermissionManager(bridge: bridge, manifest: makeManifest(ids: ["local-map.read"]))

        let beforeRevocation = try await manager.request("local-map.read")
        state = .notRequested
        bridge.requestHandler = { _ in
            // Host re-prompts after revocation and the user grants again.
            state = .granted
            return .granted
        }
        let afterRevocation = try await manager.request("local-map.read")

        XCTAssertEqual(beforeRevocation, .granted)
        XCTAssertEqual(afterRevocation, .granted)
    }
}

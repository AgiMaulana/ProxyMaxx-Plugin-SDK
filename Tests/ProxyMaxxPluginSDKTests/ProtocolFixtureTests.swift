import XCTest
@testable import ProxyMaxxPluginSDK

/// SDK-04: the SDK's wire fixtures must match Docs/PROTOCOL.md exactly — field
/// names, types, and presence — for every Protocol v1 message.
final class ProtocolFixtureTests: XCTestCase {
    private var source: ScriptedLineSource!
    private var sink: CapturingLineSink!
    private var bridge: JSONLinesBridge!

    override func setUpWithError() throws {
        source = ScriptedLineSource()
        sink = CapturingLineSink()
        bridge = JSONLinesBridge(lineSource: source, sink: sink)
    }

    override func tearDown() {
        source.enqueue(nil)
        super.tearDown()
    }

    func assertRequestLine(
        _ message: [String: Any],
        kind: String,
        permissionId: String? = nil,
        permissionIds: [String]? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let keys = Set(message.keys)
        let expected: Set<String> = permissionIds != nil
            ? ["kind", "requestId", "permissionIds"]
            : ["kind", "requestId", "permissionId"]
        XCTAssertEqual(keys, expected, "keys for \(kind)", file: file, line: line)
        XCTAssertEqual(message["kind"] as? String, kind, file: file, line: line)
        let requestId = try XCTUnwrap(message["requestId"] as? String, "requestId must be a string", file: file, line: line)
        XCTAssertFalse(requestId.isEmpty, file: file, line: line)
        if let permissionId {
            XCTAssertEqual(message["permissionId"] as? String, permissionId, file: file, line: line)
        }
        if let permissionIds {
            XCTAssertEqual(message["permissionIds"] as? [String], permissionIds, "batch preserves input order", file: file, line: line)
        }
        return requestId
    }

    func testRequestMessageFixture() async throws {
        async let reply = bridge.request("local-map.read")
        try await pollUntil { !sink.written.isEmpty }
        let requestId = try assertRequestLine(sink.written[0], kind: "permission.request", permissionId: "local-map.read")
        source.enqueue(statusReply(requestId: requestId, .granted))
        _ = try await reply
    }

    func testRequestAllMessageFixturePreservesInputOrder() async throws {
        let ids = ["local-map.read", "local-map.create", "local-map.update"]
        async let reply = bridge.requestAll(ids)
        try await pollUntil { !sink.written.isEmpty }
        let requestId = try assertRequestLine(sink.written[0], kind: "permission.requestAll", permissionIds: ids)
        source.enqueue(statusesReply(requestId: requestId, [
            "local-map.read": .granted,
            "local-map.create": .denied,
            "local-map.update": .unavailable,
        ]))
        let statuses = try await reply
        XCTAssertEqual(statuses["local-map.read"], .granted)
        XCTAssertEqual(statuses["local-map.create"], .denied)
        XCTAssertEqual(statuses["local-map.update"], .unavailable)
    }

    func testCheckMessageFixture() async throws {
        async let reply = bridge.check("local-map.read")
        try await pollUntil { !sink.written.isEmpty }
        let requestId = try assertRequestLine(sink.written[0], kind: "permission.check", permissionId: "local-map.read")
        source.enqueue(statusReply(requestId: requestId, .notRequested))
        _ = try await reply
    }

    func testCheckAllMessageFixture() async throws {
        let ids = ["local-map.read", "local-map.delete"]
        async let reply = bridge.checkAll(ids)
        try await pollUntil { !sink.written.isEmpty }
        let requestId = try assertRequestLine(sink.written[0], kind: "permission.checkAll", permissionIds: ids)
        source.enqueue(statusesReply(requestId: requestId, [
            "local-map.read": .granted,
            "local-map.delete": .notRequested,
        ]))
        _ = try await reply
    }

    func testCancelMessageFixture() async throws {
        let task = Task { try await bridge.request("local-map.read") }
        try await pollUntil { !sink.written.isEmpty }
        let requestId = try assertRequestLine(sink.written[0], kind: "permission.request", permissionId: "local-map.read")

        task.cancel()
        _ = try? await task.value

        try await pollUntil {
            self.sink.written.contains { ($0["kind"] as? String) == "permission.cancel" }
        }
        let cancelLine = sink.written.first { ($0["kind"] as? String) == "permission.cancel" }!
        XCTAssertEqual(Set(cancelLine.keys), ["kind", "requestId"])
        XCTAssertEqual(cancelLine["requestId"] as? String, requestId)
    }

    func testHostReplyFixturesParse() throws {
        // permission.status
        let statusObject = try JSONSerialization.jsonObject(with: statusReply(requestId: "R1", .granted).data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(Set(statusObject.keys), ["kind", "requestId", "status"])
        XCTAssertEqual(statusObject["kind"] as? String, "permission.status")
        XCTAssertEqual(statusObject["status"] as? String, "GRANTED")

        // permission.statuses — uppercase wire values, one entry per id
        let statusesObject = try JSONSerialization.jsonObject(
            with: statusesReply(requestId: "R2", ["local-map.read": .granted, "local-map.create": .notRequested]).data(using: .utf8)!
        ) as! [String: Any]
        XCTAssertEqual(Set(statusesObject.keys), ["kind", "requestId", "statuses"])
        let statuses = try XCTUnwrap(statusesObject["statuses"] as? [String: String])
        XCTAssertEqual(statuses, ["local-map.read": "GRANTED", "local-map.create": "NOT_REQUESTED"])

        // permission.cancelled
        let cancelledObject = try JSONSerialization.jsonObject(with: cancelledReply(requestId: "R3").data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(Set(cancelledObject.keys), ["kind", "requestId"])
        XCTAssertEqual(cancelledObject["kind"] as? String, "permission.cancelled")

        // permission.error
        let errorObject = try JSONSerialization.jsonObject(with: encodedLine(["kind": "permission.error", "requestId": "R4", "error": "hostUnavailable"]).data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(Set(errorObject.keys), ["kind", "requestId", "error"])
    }

    func testMalformedResponseFailsChannelClosed() async throws {
        let task = Task { try await bridge.request("local-map.read") }
        try await pollUntil { !sink.written.isEmpty }
        source.enqueue("[1, 2, 3]") // valid JSON, but not an object

        do {
            _ = try await task.value
            XCTFail("Expected hostUnavailable")
        } catch let error as PermissionError {
            XCTAssertEqual(error, .hostUnavailable)
        }
        // Channel closed: subsequent requests fail immediately.
        do {
            _ = try await bridge.check("local-map.read")
            XCTFail("Expected hostUnavailable")
        } catch let error as PermissionError {
            XCTAssertEqual(error, .hostUnavailable)
        }
    }
}

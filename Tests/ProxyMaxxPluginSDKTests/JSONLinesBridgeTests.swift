import XCTest
@testable import ProxyMaxxPluginSDK

/// Exercises the JSON-lines wire contract end to end with a scripted host
/// channel (protocol v1, Docs/PROTOCOL.md).
final class JSONLinesBridgeTests: XCTestCase {
    private func makeBridge(
        source: ScriptedLineSource,
        sink: CapturingLineSink
    ) -> JSONLinesBridge {
        JSONLinesBridge(lineSource: source, sink: sink)
    }

    func testRequestRoundTripSendsProtocolV1Message() async throws {
        let source = ScriptedLineSource()
        let sink = CapturingLineSink()
        let bridge = makeBridge(source: source, sink: sink)
        defer { source.enqueue(nil) }

        let task = Task { try await bridge.request("local-map.read") }
        try await pollUntil { !sink.written.isEmpty }

        let sent = sink.written[0]
        XCTAssertEqual(sent["kind"] as? String, "permission.request")
        XCTAssertEqual(sent["permissionId"] as? String, "local-map.read")

        let requestId = try XCTUnwrap(sent["requestId"] as? String)
        source.enqueue(statusReply(requestId: requestId, .granted))

        let status = try await task.value
        XCTAssertEqual(status, .granted)
    }

    func testCheckSendsCheckKindAndAcceptsNotRequested() async throws {
        let source = ScriptedLineSource()
        let sink = CapturingLineSink()
        let bridge = makeBridge(source: source, sink: sink)
        defer { source.enqueue(nil) }

        let task = Task { try await bridge.check("local-map.read") }
        try await pollUntil { !sink.written.isEmpty }
        XCTAssertEqual(sink.written[0]["kind"] as? String, "permission.check")

        let requestId = try XCTUnwrap(sink.written[0]["requestId"] as? String)
        source.enqueue(statusReply(requestId: requestId, .notRequested))

        let status = try await task.value
        XCTAssertEqual(status, .notRequested)
    }

    func testConcurrentRequestsCorrelateByRequestId() async throws {
        let source = ScriptedLineSource()
        let sink = CapturingLineSink()
        let bridge = makeBridge(source: source, sink: sink)
        defer { source.enqueue(nil) }

        let readTask = Task { try await bridge.request("local-map.read") }
        let createTask = Task { try await bridge.request("local-map.create") }
        try await pollUntil { sink.written.count == 2 }

        // Reply in the opposite order of the requests to prove correlation.
        for sent in sink.written.reversed() {
            let id = try XCTUnwrap(sent["requestId"] as? String)
            let status = (sent["permissionId"] as? String) == "local-map.read"
                ? PermissionStatus.granted
                : .denied
            source.enqueue(statusReply(requestId: id, status))
        }

        let readStatus = try await readTask.value
        let createStatus = try await createTask.value
        XCTAssertEqual(readStatus, .granted)
        XCTAssertEqual(createStatus, .denied)
    }

    func testRequestAllSendsSingleBatchMessageAndParsesStatusesReply() async throws {
        let source = ScriptedLineSource()
        let sink = CapturingLineSink()
        let bridge = makeBridge(source: source, sink: sink)
        defer { source.enqueue(nil) }

        let ids = ["local-map.read", "local-map.create"]
        let task = Task { try await bridge.requestAll(ids) }
        try await pollUntil { !sink.written.isEmpty }

        let sent = sink.written[0]
        XCTAssertEqual(sent["kind"] as? String, "permission.requestAll")
        XCTAssertEqual(sent["permissionIds"] as? [String], ids)

        let requestId = try XCTUnwrap(sent["requestId"] as? String)
        source.enqueue(statusesReply(requestId: requestId, [
            "local-map.read": .granted,
            "local-map.create": .denied,
        ]))

        let statuses = try await task.value
        XCTAssertEqual(statuses, ["local-map.read": .granted, "local-map.create": .denied])
    }

    func testMalformedReplyLineFailsAllPendingRequests() async throws {
        let source = ScriptedLineSource()
        let sink = CapturingLineSink()
        let bridge = makeBridge(source: source, sink: sink)

        let task = Task { try await bridge.request("local-map.read") }
        try await pollUntil { !sink.written.isEmpty }

        source.enqueue("this is not json")

        do {
            _ = try await task.value
            XCTFail("Expected hostUnavailable")
        } catch let error as PermissionError {
            XCTAssertEqual(error, .hostUnavailable)
        }

        // Channel is closed after a malformed line; new requests fail fast.
        do {
            _ = try await bridge.request("local-map.read")
            XCTFail("Expected hostUnavailable")
        } catch let error as PermissionError {
            XCTAssertEqual(error, .hostUnavailable)
        }
    }

    func testUnknownStatusStringFailsClosed() async throws {
        let source = ScriptedLineSource()
        let sink = CapturingLineSink()
        let bridge = makeBridge(source: source, sink: sink)

        let task = Task { try await bridge.request("local-map.read") }
        try await pollUntil { !sink.written.isEmpty }
        let requestId = try XCTUnwrap(sink.written[0]["requestId"] as? String)
        source.enqueue(encodedLine([
            "kind": "permission.status",
            "requestId": requestId,
            "status": "MAYBE",
        ]))

        do {
            _ = try await task.value
            XCTFail("Expected hostUnavailable")
        } catch let error as PermissionError {
            XCTAssertEqual(error, .hostUnavailable)
        }
    }

    func testReplyForUnknownRequestIdIsIgnored() async throws {
        let source = ScriptedLineSource()
        let sink = CapturingLineSink()
        let bridge = makeBridge(source: source, sink: sink)
        defer { source.enqueue(nil) }

        let task = Task { try await bridge.request("local-map.read") }
        try await pollUntil { !sink.written.isEmpty }
        let requestId = try XCTUnwrap(sink.written[0]["requestId"] as? String)

        // Stale/foreign reply must not resolve or break the pending request.
        source.enqueue(statusReply(requestId: "bogus-id", .denied))
        source.enqueue(statusReply(requestId: requestId, .granted))

        let status = try await task.value
        XCTAssertEqual(status, .granted)
    }

    func testPermissionErrorMessageFailsRequest() async throws {
        let source = ScriptedLineSource()
        let sink = CapturingLineSink()
        let bridge = makeBridge(source: source, sink: sink)

        let task = Task { try await bridge.request("local-map.read") }
        try await pollUntil { !sink.written.isEmpty }
        let requestId = try XCTUnwrap(sink.written[0]["requestId"] as? String)
        source.enqueue(encodedLine([
            "kind": "permission.error",
            "requestId": requestId,
            "error": "hostUnavailable",
        ]))

        do {
            _ = try await task.value
            XCTFail("Expected hostUnavailable")
        } catch let error as PermissionError {
            XCTAssertEqual(error, .hostUnavailable)
        }
    }

    func testUnknownMessageKindIsIgnored() async throws {
        let source = ScriptedLineSource()
        let sink = CapturingLineSink()
        let bridge = makeBridge(source: source, sink: sink)
        defer { source.enqueue(nil) }

        let task = Task { try await bridge.request("local-map.read") }
        try await pollUntil { !sink.written.isEmpty }
        let requestId = try XCTUnwrap(sink.written[0]["requestId"] as? String)
        source.enqueue(encodedLine(["kind": "host.log", "message": "unrelated"]))
        source.enqueue(statusReply(requestId: requestId, .granted))

        let status = try await task.value
        XCTAssertEqual(status, .granted)
    }

    func testChannelEndFailsPendingRequests() async throws {
        let source = ScriptedLineSource()
        let sink = CapturingLineSink()
        let bridge = makeBridge(source: source, sink: sink)

        let task = Task { try await bridge.request("local-map.read") }
        try await pollUntil { !sink.written.isEmpty }

        source.enqueue(nil) // host closed the channel

        do {
            _ = try await task.value
            XCTFail("Expected hostUnavailable")
        } catch let error as PermissionError {
            XCTAssertEqual(error, .hostUnavailable)
        }
    }

    func testEncodedMessagesAreSortedAndNewlineTerminated() throws {
        let data = try JSONLines.encode(["kind": "permission.request", "requestId": "A1", "permissionId": "x"])
        let text = String(data: data, encoding: .utf8)!
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertEqual(
            text.trimmingCharacters(in: .newlines),
            #"{"kind":"permission.request","permissionId":"x","requestId":"A1"}"#
        )
    }
}

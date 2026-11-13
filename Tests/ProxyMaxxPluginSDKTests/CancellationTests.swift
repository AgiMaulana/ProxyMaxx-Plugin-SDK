import XCTest
@testable import ProxyMaxxPluginSDK

final class CancellationTests: XCTestCase {
    func testTaskCancellationSendsCancelMessageAndThrowsCancellationError() async throws {
        let source = ScriptedLineSource()
        let sink = CapturingLineSink()
        let bridge = JSONLinesBridge(lineSource: source, sink: sink)
        defer { source.enqueue(nil) }

        let task = Task { try await bridge.request("local-map.read") }
        try await pollUntil { !sink.written.isEmpty }
        let requestId = try XCTUnwrap(sink.written[0]["requestId"] as? String)
        XCTAssertEqual(sink.written[0]["kind"] as? String, "permission.request")

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Spec §7.2: cancellation propagates as cancellation, not a status.
        }

        try await pollUntil {
            firstRequestId(ofKind: "permission.cancel", in: sink.written) != nil
        }
        let cancelMessage = sink.written.first { ($0["kind"] as? String) == "permission.cancel" }
        XCTAssertEqual(cancelMessage?["requestId"] as? String, requestId)
    }

    func testHostCancelledReplyThrowsCancellationError() async throws {
        // Spec §7.2: consent dismissal arrives as permission.cancelled; the SDK
        // must convert it to cancellation, never to DENIED/NOT_REQUESTED.
        let source = ScriptedLineSource()
        let sink = CapturingLineSink()
        let bridge = JSONLinesBridge(lineSource: source, sink: sink)
        defer { source.enqueue(nil) }

        let task = Task { try await bridge.request("local-map.read") }
        try await pollUntil { !sink.written.isEmpty }
        let requestId = try XCTUnwrap(sink.written[0]["requestId"] as? String)

        source.enqueue(cancelledReply(requestId: requestId))

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Correct: no decision recorded.
        }
    }

    func testCancelledBatchSendsSingleCancelMessage() async throws {
        let source = ScriptedLineSource()
        let sink = CapturingLineSink()
        let bridge = JSONLinesBridge(lineSource: source, sink: sink)
        defer { source.enqueue(nil) }

        let task = Task {
            try await bridge.requestAll(["local-map.read", "local-map.create"])
        }
        try await pollUntil { !sink.written.isEmpty }
        let requestId = try XCTUnwrap(sink.written[0]["requestId"] as? String)
        XCTAssertEqual(sink.written[0]["kind"] as? String, "permission.requestAll")

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {}

        try await pollUntil {
            firstRequestId(ofKind: "permission.cancel", in: sink.written) != nil
        }
        let cancelMessage = sink.written.first { ($0["kind"] as? String) == "permission.cancel" }
        XCTAssertEqual(cancelMessage?["requestId"] as? String, requestId)
    }

    func testCancellationBeforeRegistrationDoesNotContactHost() async throws {
        let source = ScriptedLineSource()
        let sink = CapturingLineSink()
        let bridge = JSONLinesBridge(lineSource: source, sink: sink)
        defer { source.enqueue(nil) }

        // Cancel before the operation body runs; the handler runs first and the
        // request must never reach the host.
        let task = Task { try await bridge.request("local-map.read") }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {}

        // Give the reader a beat, then assert nothing was sent.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(sink.written.isEmpty, "No wire message expected, got \(sink.written)")
    }

    func testManagerPropagatesCancellationError() async throws {
        let source = ScriptedLineSource()
        let sink = CapturingLineSink()
        let bridge = JSONLinesBridge(lineSource: source, sink: sink)
        defer { source.enqueue(nil) }
        let manager = PermissionManager(bridge: bridge, manifest: makeManifest(ids: ["local-map.read"]))

        let task = Task { try await manager.request("local-map.read") }
        try await pollUntil { !sink.written.isEmpty }

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {}
    }

    func testCompletedRequestIsNotCancelledLate() async throws {
        let source = ScriptedLineSource()
        let sink = CapturingLineSink()
        let bridge = JSONLinesBridge(lineSource: source, sink: sink)
        defer { source.enqueue(nil) }

        let task = Task { try await bridge.request("local-map.read") }
        try await pollUntil { !sink.written.isEmpty }
        let requestId = try XCTUnwrap(sink.written[0]["requestId"] as? String)
        source.enqueue(statusReply(requestId: requestId, .granted))

        let status = try await task.value
        XCTAssertEqual(status, .granted)

        // Cancelling an already-completed task must not emit a cancel message.
        task.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(firstRequestId(ofKind: "permission.cancel", in: sink.written))
    }
}

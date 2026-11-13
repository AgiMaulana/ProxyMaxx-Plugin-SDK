import XCTest
@testable import ProxyMaxxPluginSDK

/// SDK-03 acceptance criteria: request lifecycle, cancellation bookkeeping
/// bounds, and exactly-once resolution.
final class PendingRequestTableTests: XCTestCase {
    func testCancelOfUnregisteredIdIsANoopAndRegistrationProceeds() async throws {
        // Pre-registration cancellation is detected through the task's own
        // cancellation state (see the bridge's withTaskCancellationHandler), not
        // through per-id bookkeeping. A cancel event for an id that never
        // registered is therefore a no-op: the table keeps no records, and a
        // registration from a non-cancelled task proceeds normally.
        let table = PendingRequestTable()
        XCTAssertFalse(table.cancel("A"))

        async let reply = table.awaitReply(for: "A", onStart: {})
        try await pollUntil { table.outstandingCount == 1 }
        XCTAssertTrue(table.fulfill("A", with: .status(.granted)))

        let status = try await reply
        if case .status(.granted) = status {} else {
            XCTFail("Expected granted status")
        }
        XCTAssertEqual(table.bookkeepingCount, 0)
    }

    func testCancelledTaskThrowsAtRegistrationWithoutOnStartOrBookkeeping() async throws {
        // The real bridge sequence: withTaskCancellationHandler installs the
        // handler, an already-cancelled task fires it immediately (the handler
        // finds nothing pending), and registration observes Task.isCancelled.
        let table = PendingRequestTable()
        let task = Task {
            try await table.awaitReply(for: "A", onStart: {
                XCTFail("onStart must not run for a cancelled request")
            })
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {}

        XCTAssertEqual(table.bookkeepingCount, 0)
        XCTAssertEqual(table.outstandingCount, 0)
    }

    func testCancelWhilePendingResumesOnce() async throws {
        let table = PendingRequestTable()

        async let reply = table.awaitReply(for: "A", onStart: {})
        try await pollUntil { table.outstandingCount == 1 }

        XCTAssertTrue(table.cancel("A"))
        do {
            _ = try await reply
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Correct: cancellation propagates.
        }

        // Repeated cancellation attempts after resolution must not resume
        // again (exactly-once) or create bookkeeping.
        XCTAssertFalse(table.cancel("A"))
        XCTAssertFalse(table.cancel("A"))
        XCTAssertEqual(table.bookkeepingCount, 0)
    }

    func testFulfilledRequestThenLateCancelCreatesNoBookkeeping() async throws {
        let table = PendingRequestTable()

        async let reply = table.awaitReply(for: "A", onStart: {})
        try await pollUntil { table.outstandingCount == 1 }
        XCTAssertTrue(table.fulfill("A", with: .status(.granted)))

        let status = try await reply
        if case .status(.granted) = status {} else {
            XCTFail("Expected granted status")
        }

        // Cancellation after completion: no bookkeeping, no reinsertion.
        XCTAssertFalse(table.cancel("A"))
        XCTAssertEqual(table.bookkeepingCount, 0)
    }

    func testLateReplyAfterCancellationIsIgnored() async throws {
        let table = PendingRequestTable()

        async let reply = table.awaitReply(for: "A", onStart: {})
        try await pollUntil { table.outstandingCount == 1 }

        XCTAssertTrue(table.cancel("A"))
        do {
            _ = try await reply
            XCTFail("Expected CancellationError")
        } catch is CancellationError {}

        // The late host reply must not resolve anything (the id is already
        // resolved; fulfill returns false).
        XCTAssertFalse(table.fulfill("A", with: .status(.denied)))
    }

    func testFailAllResolvesEveryPendingRequestExactlyOnce() async throws {
        let table = PendingRequestTable()
        var tasks: [Task<PendingRequestTable.Reply, Error>] = []
        for id in ["A", "B", "C"] {
            tasks.append(Task { try await table.awaitReply(for: id, onStart: {}) })
        }
        try await pollUntil { table.outstandingCount == 3 }

        table.failAll(with: PermissionError.hostUnavailable)

        for task in tasks {
            do {
                _ = try await task.value
                XCTFail("Expected hostUnavailable")
            } catch let error as PermissionError {
                XCTAssertEqual(error, .hostUnavailable)
            }
        }
        XCTAssertEqual(table.outstandingCount, 0)
        // Cancel attempts after the bulk failure create no bookkeeping.
        XCTAssertFalse(table.cancel("A"))
        XCTAssertEqual(table.bookkeepingCount, 0)
    }

    func testDuplicateRegistrationFailsClosed() async throws {
        let table = PendingRequestTable()

        async let first = table.awaitReply(for: "A", onStart: {})
        try await pollUntil { table.outstandingCount == 1 }

        do {
            _ = try await table.awaitReply(for: "A", onStart: {})
            XCTFail("Expected hostUnavailable for duplicate id")
        } catch let error as PermissionError {
            XCTAssertEqual(error, .hostUnavailable)
        }

        XCTAssertTrue(table.fulfill("A", with: .status(.granted)))
        let result = try await first
        if case .status(.granted) = result {} else {
            XCTFail("Expected granted status")
        }
    }

    func testCancelBeforeRegistrationCreatesNoBookkeeping() {
        let table = PendingRequestTable()
        // Cancellation before registration is detected via the task's own
        // cancellation state at registration; no id records are kept.
        for index in 0..<500 {
            table.cancel("pre-\(index)")
        }
        XCTAssertEqual(table.bookkeepingCount, 0)
        XCTAssertEqual(table.outstandingCount, 0)
    }

    func testResolvedHistoryIsBounded() async throws {
        let table = PendingRequestTable()
        for index in 0..<150 {
            let id = "resolved-\(index)"
            async let reply = table.awaitReply(for: id, onStart: {})
            try await pollUntil { table.outstandingCount == 1 }
            // Fail fast instead of hanging if a poll timed out and registration
            // raced with this loop's bookkeeping.
            guard table.outstandingCount == 1, table.fulfill(id, with: .status(.granted)) else {
                XCTFail("registration/fulfill race at iteration \(index)")
                break
            }
            _ = try await reply
        }
        // 150 resolutions exceed maxResolvedHistory (128) and must stay capped.
        XCTAssertLessThanOrEqual(table.resolvedHistoryCount, PendingRequestTable.maxResolvedHistory)
        XCTAssertEqual(table.bookkeepingCount, 0)
    }
}

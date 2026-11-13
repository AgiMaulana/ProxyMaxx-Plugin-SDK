import XCTest
@testable import ProxyMaxxPluginSDK

/// SDK-03 acceptance criteria: request lifecycle, cancellation bookkeeping
/// bounds, and exactly-once resolution.
final class PendingRequestTableTests: XCTestCase {
    func testCancelBeforeRegistrationConsumesAtRegistrationAndSendsNothing() async throws {
        let table = PendingRequestTable()
        table.cancel("A")

        do {
            _ = try await table.awaitReply(for: "A", onStart: {
                XCTFail("onStart must not run for a cancelled request")
            })
            XCTFail("Expected CancellationError")
        } catch is CancellationError {}

        // Bookkeeping consumed at registration.
        XCTAssertEqual(table.bookkeepingCount, 0)
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

    func testBookkeepingIsBoundedForNeverRegisteredCancellations() {
        let table = PendingRequestTable()
        for index in 0..<500 {
            table.cancel("pre-\(index)")
        }
        XCTAssertLessThanOrEqual(table.bookkeepingCount, PendingRequestTable.maxOutstanding)
    }

    func testResolvedHistoryIsBounded() async throws {
        let table = PendingRequestTable()
        for index in 0..<150 {
            let id = "resolved-\(index)"
            async let reply = table.awaitReply(for: id, onStart: {})
            try await pollUntil { table.outstandingCount == 1 }
            XCTAssertTrue(table.fulfill(id, with: .status(.granted)))
            _ = try await reply
        }
        // 150 resolutions exceed maxResolvedHistory (128) and must stay capped.
        XCTAssertLessThanOrEqual(table.bookkeepingCount, PendingRequestTable.maxOutstanding)
    }

    func testCancellationRecordsClearedWhenRequestResolves() async throws {
        let table = PendingRequestTable()
        table.cancel("A")
        XCTAssertEqual(table.bookkeepingCount, 1)

        async let reply = table.awaitReply(for: "A", onStart: {})
        try await pollUntil { table.bookkeepingCount == 0 }
        do {
            _ = try await reply
            XCTFail("Expected CancellationError")
        } catch is CancellationError {}
    }
}

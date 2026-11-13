import XCTest
@testable import ProxyMaxxPluginSDK

/// SDK-02 acceptance criteria: per-line framing enforcement on `Framer` and on
/// a real pipe via `FileHandleLineSource`.
final class FramerTests: XCTestCase {
    private let limit = 64

    // MARK: Framer unit tests

    func testExtractsMultipleLinesAcrossFeeds() throws {
        let framer = Framer(maxLineBytes: limit)
        try framer.feed(Data("{\"a\":1}\n{\"b\":".utf8))
        XCTAssertEqual(try framer.nextLine(), "{\"a\":1}")
        XCTAssertNil(try framer.nextLine(), "partial line: more data needed")
        try framer.feed(Data("2}\n".utf8))
        XCTAssertEqual(try framer.nextLine(), "{\"b\":2}")
    }

    func testMultipleValidLinesInOneChunkOverCombinedLimitAreAccepted() throws {
        let framer = Framer(maxLineBytes: limit)
        let line = String(repeating: "x", count: 40) // 40 bytes each, 2 lines > 64 combined
        try framer.feed(Data("\(line)\n\(line)\n".utf8))
        XCTAssertEqual(try framer.nextLine(), line)
        XCTAssertEqual(try framer.nextLine(), line)
        XCTAssertNil(try framer.nextLine())
    }

    func testOversizedCompleteLineInOneChunkThrows() {
        let framer = Framer(maxLineBytes: limit)
        XCTAssertThrowsError(try framer.feed(Data((String(repeating: "x", count: limit + 1) + "\n").utf8)))
    }

    func testOversizedIncompleteLineThrowsBeforeNewline() {
        let framer = Framer(maxLineBytes: limit)
        XCTAssertThrowsError(try framer.feed(Data(String(repeating: "x", count: limit + 1).utf8)))
    }

    func testOversizedLineSplitAcrossChunksThrows() throws {
        let framer = Framer(maxLineBytes: limit)
        try framer.feed(Data(String(repeating: "x", count: limit - 10).utf8)) // still incomplete, fine
        XCTAssertThrowsError(try framer.feed(Data(String(repeating: "x", count: 20).utf8)))
    }

    func testValidLineFollowedByOversizedLineInSameChunkThrows() throws {
        let framer = Framer(maxLineBytes: limit)
        let valid = String(repeating: "x", count: 10)
        let oversized = String(repeating: "y", count: limit + 1)
        // Fail closed on the whole chunk when any line is oversized.
        XCTAssertThrowsError(try framer.feed(Data("\(valid)\n\(oversized)\n".utf8)))
    }

    func testCleanEOFAfterDrainedBufferReturnsNil() throws {
        let framer = Framer(maxLineBytes: limit)
        try framer.feed(Data("line\n".utf8))
        XCTAssertEqual(try framer.nextLine(), "line")
        framer.markEndOfFile()
        XCTAssertNil(try framer.nextLine())
    }

    func testEOFWithPartialLineThrows() throws {
        let framer = Framer(maxLineBytes: limit)
        try framer.feed(Data("unterminated".utf8))
        XCTAssertNil(try framer.nextLine(), "need more data")
        framer.markEndOfFile()
        XCTAssertThrowsError(try framer.nextLine())
    }

    func testInvalidUTF8ThrowsAtNextLine() throws {
        let framer = Framer(maxLineBytes: limit)
        // Valid ASCII newline-delimited frame whose payload is invalid UTF-8.
        var data = Data([0xFF, 0xFE])
        data.append(Data("\n".utf8))
        try framer.feed(data)
        XCTAssertThrowsError(try framer.nextLine())
    }

    func testLineAtExactlyTheLimitIsAccepted() throws {
        let framer = Framer(maxLineBytes: limit)
        try framer.feed(Data((String(repeating: "x", count: limit) + "\n").utf8))
        XCTAssertEqual(try framer.nextLine()?.count, limit)
    }

    // MARK: Pipe end-to-end tests

    func testPipeSourceDeliversChunkedLinesAndCleanEOF() async throws {
        let pipe = Pipe()
        let source = FileHandleLineSource(handle: pipe.fileHandleForReading)

        try pipe.fileHandleForWriting.write(contentsOf: Data("first\nse".utf8))
        let first = try await source.readLine()
        XCTAssertEqual(first, "first")
        try pipe.fileHandleForWriting.write(contentsOf: Data("cond\n".utf8))
        let second = try await source.readLine()
        XCTAssertEqual(second, "second")

        try pipe.fileHandleForWriting.close()
        let eof = try await source.readLine()
        XCTAssertNil(eof)
    }

    func testPipeSourceFailsOnOversizedLine() async throws {
        let pipe = Pipe()
        let source = FileHandleLineSource(handle: pipe.fileHandleForReading, maxLineBytes: 16)

        try pipe.fileHandleForWriting.write(contentsOf: Data((String(repeating: "z", count: 40) + "\n").utf8))
        do {
            _ = try await source.readLine()
            XCTFail("Expected framing failure")
        } catch let error as PermissionError {
            XCTAssertEqual(error, .hostUnavailable)
        }
        try pipe.fileHandleForWriting.close()
    }

    func testOutgoingEncodeEnforcesSizeLimit() throws {
        XCTAssertThrowsError(try JSONLines.encode(["big": String(repeating: "a", count: 1_048_577)]))
        XCTAssertNoThrow(try JSONLines.encode(["ok": "value"]))
    }
}

import Foundation

/// JSON-lines codec helpers. One JSON object per line, newline-delimited.
enum JSONLines {
    /// Maximum encoded line length in bytes. Mirrors the host runner's bounded
    /// line policy; longer lines fail closed.
    static let maxLineLength = 1_048_576

    static func encode(_ object: [String: Any]) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return json + Data([0x0A])
    }

    static func decode(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8), !data.isEmpty else { return nil }
        let object = try? JSONSerialization.jsonObject(with: data, options: [])
        return object as? [String: Any]
    }
}

/// Sinks encoded lines to the host channel.
public protocol LineSink: Sendable, AnyObject {
    func write(_ object: [String: Any]) throws
}

/// Writes JSON lines to a file handle with a lock, so request threads and
/// cancellation handlers can write concurrently without interleaving.
final class FileHandleLineSink: LineSink, @unchecked Sendable {
    private struct Box: @unchecked Sendable { let value: FileHandle }

    private let box: Box
    private let lock = NSLock()
    private var closed = false

    init(handle: FileHandle) {
        box = Box(value: handle)
    }

    func write(_ object: [String: Any]) throws {
        let line = try JSONLines.encode(object)
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw PermissionError.hostUnavailable }
        do {
            try box.value.write(contentsOf: line)
        } catch {
            closed = true
            throw PermissionError.hostUnavailable
        }
    }
}

/// Test/embedder sink collecting written lines for inspection.
public final class CapturingLineSink: LineSink, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [[String: Any]] = []

    public init() {}

    public func write(_ object: [String: Any]) throws {
        lock.lock()
        defer { lock.unlock() }
        lines.append(object)
    }

    public var written: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

/// Sources incoming lines from the host channel.
public protocol LineSource: Sendable, AnyObject {
    /// Returns the next line, or `nil` at end of channel. Throws on transport
    /// failure or an over-long line.
    func readLine() async throws -> String?
}

/// Reads JSON lines from a file handle (the plugin's stdin when spawned by the
/// host runner). Blocking reads run on detached tasks so callers stay in
/// structured concurrency.
final class FileHandleLineSource: LineSource, @unchecked Sendable {
    private struct Box: @unchecked Sendable { let value: FileHandle }

    private let box: Box
    private let lock = NSLock()
    private var buffer = Data()
    private var endOfChannel = false

    init(handle: FileHandle) {
        box = Box(value: handle)
    }

    func readLine() async throws -> String? {
        while true {
            if let line = takeCompleteLine() {
                return line
            }
            if isAtEnd() { return nil }

            let chunk = try await Task.detached { [box] () -> Data in
                box.value.availableData
            }.value

            if chunk.isEmpty {
                markAtEnd()
                continue
            }
            try append(chunk)
        }
    }

    private func isAtEnd() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return endOfChannel
    }

    private func markAtEnd() {
        lock.lock()
        defer { lock.unlock() }
        endOfChannel = true
    }

    private func takeCompleteLine() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
        let lineData = buffer.subdata(in: buffer.startIndex..<newline)
        buffer.removeSubrange(buffer.startIndex...newline)
        return String(data: lineData, encoding: .utf8)
    }

    private func append(_ chunk: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        guard buffer.count <= JSONLines.maxLineLength else {
            endOfChannel = true
            throw PermissionError.hostUnavailable
        }
    }
}

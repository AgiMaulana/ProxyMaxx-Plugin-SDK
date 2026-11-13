import Foundation

/// JSON-lines codec helpers. One JSON object per line, newline-delimited.
///
/// The line limit is enforced **per line**: a chunk may legitimately contain
/// multiple valid lines whose combined size exceeds the limit, while a single
/// line (complete or still accumulating) past the limit fails the channel.
enum JSONLines {
    /// Maximum encoded line length in bytes (the byte count before the newline
    /// delimiter). Mirrors the host runner's bounded line policy.
    static let maxLineLength = 1_048_576

    /// Encodes one message. Throws when the encoded line exceeds the limit, so
    /// outgoing traffic obeys the same bound as incoming traffic.
    static func encode(
        _ object: [String: Any],
        maxLineBytes: Int = JSONLines.maxLineLength
    ) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard json.count <= maxLineBytes else {
            throw PermissionError.hostUnavailable
        }
        return json + Data([0x0A])
    }

    static func decode(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8), !data.isEmpty else { return nil }
        let object = try? JSONSerialization.jsonObject(with: data, options: [])
        return object as? [String: Any]
    }
}

/// Byte-level framing for the incoming JSON-lines channel.
///
/// Violations throw `PermissionError.hostUnavailable` so callers can fail the
/// channel closed (fail every outstanding request, reject later requests):
/// - A line — complete or still accumulating — longer than `maxLineBytes`.
/// - A complete line that is not valid UTF-8.
/// - End of channel while a partial line remains buffered.
final class Framer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var sawEOF = false
    private let maxLineBytes: Int

    init(maxLineBytes: Int = JSONLines.maxLineLength) {
        self.maxLineBytes = maxLineBytes
    }

    /// Records a clean end of channel. A later `nextLine()` returns `nil` when
    /// nothing is buffered, or throws when a partial line remains.
    func markEndOfFile() {
        lock.lock()
        defer { lock.unlock() }
        sawEOF = true
    }

    /// `true` once `markEndOfFile()` was called and the buffer is drained.
    func isAtEOF() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sawEOF && buffer.isEmpty
    }

    /// Appends a read chunk. The chunk may hold any number of complete lines;
    /// only individual line sizes are bounded.
    func feed(_ chunk: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        if buffer.firstIndex(of: 0x0A) == nil {
            // No newline anywhere: this whole chunk extends one incomplete line.
            guard buffer.count <= maxLineBytes else {
                throw PermissionError.hostUnavailable
            }
            return
        }
        // Complete lines end at every newline; each must fit the limit. The
        // bytes after the last newline start the next (still incomplete) line.
        var lineStart = buffer.startIndex
        var searchStart = lineStart
        while let newline = buffer[searchStart...].firstIndex(of: 0x0A) {
            if newline - lineStart > maxLineBytes {
                throw PermissionError.hostUnavailable
            }
            lineStart = buffer.index(after: newline)
            searchStart = lineStart
            if lineStart >= buffer.endIndex { break }
        }
        if lineStart < buffer.endIndex, buffer[lineStart...].count > maxLineBytes {
            throw PermissionError.hostUnavailable
        }
    }

    /// Returns the next complete line. Returns `nil` when more data is needed
    /// or at a clean end of channel; throws on framing violations (over-long
    /// line, non-UTF-8 line, or EOF with a partial line buffered).
    func nextLine() throws -> String? {
        lock.lock()
        defer { lock.unlock() }

        guard let newline = buffer.firstIndex(of: 0x0A) else {
            if sawEOF {
                if buffer.isEmpty {
                    return nil // clean end of channel
                }
                throw PermissionError.hostUnavailable // EOF with a partial line
            }
            return nil // need more data
        }

        let lineData = buffer.subdata(in: buffer.startIndex..<newline)
        buffer.removeSubrange(buffer.startIndex...newline)
        guard lineData.count <= maxLineBytes else {
            throw PermissionError.hostUnavailable
        }
        guard let line = String(data: lineData, encoding: .utf8) else {
            throw PermissionError.hostUnavailable
        }
        return line
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
    private let maxLineBytes: Int

    init(handle: FileHandle, maxLineBytes: Int = JSONLines.maxLineLength) {
        box = Box(value: handle)
        self.maxLineBytes = maxLineBytes
    }

    func write(_ object: [String: Any]) throws {
        let line = try JSONLines.encode(object, maxLineBytes: maxLineBytes)
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
    private let maxLineBytes: Int

    public init(maxLineBytes: Int = 1_048_576) {
        self.maxLineBytes = maxLineBytes
    }

    public func write(_ object: [String: Any]) throws {
        _ = try JSONLines.encode(object, maxLineBytes: maxLineBytes)
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
    /// Returns the next line, or `nil` at a clean end of channel. Throws on
    /// transport or framing failure (including an over-long or non-UTF-8 line).
    func readLine() async throws -> String?
}

/// Reads JSON lines from a file handle (the plugin's stdin when spawned by the
/// host runner). Blocking reads run on detached tasks so callers stay in
/// structured concurrency. Framing is delegated to `Framer`.
final class FileHandleLineSource: LineSource, @unchecked Sendable {
    private struct Box: @unchecked Sendable { let value: FileHandle }

    private let box: Box
    private let framer: Framer

    init(handle: FileHandle, maxLineBytes: Int = JSONLines.maxLineLength) {
        box = Box(value: handle)
        framer = Framer(maxLineBytes: maxLineBytes)
    }

    func readLine() async throws -> String? {
        while true {
            if let line = try framer.nextLine() {
                return line
            }
            if framer.isAtEOF() { return nil }

            let chunk = try await Task.detached { [box] () -> Data in
                box.value.availableData
            }.value

            if chunk.isEmpty {
                framer.markEndOfFile()
                continue
            }
            try framer.feed(chunk)
        }
    }
}

import Foundation

public struct StreamLine {
    public var session: String
    public var offset: UInt64
    public var receivedAt: Date?
    public var message: String
    public var partial: Bool
}

/// Reads only new bytes. Pending input is capped at one MiB: exceptionally long
/// lines are emitted as partial fragments instead of allowing unbounded memory.
public final class LogStream {
    private let reader: SessionReader
    private var cursor: UInt64
    private var lineOffset: UInt64
    private var pending = Data()
    private var skippingPrefix = false
    private static let fragmentLimit = 1024 * 1024

    public init(snapshot: SessionSnapshot, tail: Int?, newCapture: Bool = false) throws {
        reader = try SessionReader(directory: snapshot.directory)
        if newCapture { cursor = 0 }
        else if let tail { cursor = try Self.tailStart(reader: reader, byteCount: snapshot.byteCount, count: tail) }
        else { cursor = snapshot.byteCount }
        lineOffset = cursor
        // A follower joining halfway through a line waits for the next line;
        // it must not present a suffix as though it were a whole new message.
        if (tail == nil || tail == 0) && !newCapture && cursor > 0 {
            skippingPrefix = try reader.readBytes(in: cursor - 1..<cursor).first != 0x0A
        }
    }

    public func drain(_ snapshot: SessionSnapshot, final: Bool = false, emit: (StreamLine) throws -> Void) throws {
        guard snapshot.byteCount >= cursor else { throw CLIError("Active capture was truncated") }
        while cursor < snapshot.byteCount {
            let end = min(snapshot.byteCount, cursor + 65536)
            let bytes = try reader.readBytes(in: cursor..<end)
            for byte in bytes {
                cursor += 1
                if skippingPrefix {
                    if byte == 0x0A { skippingPrefix = false; lineOffset = cursor }
                    continue
                }
                if byte == 0x0A {
                    try output(snapshot, partial: false, emit: emit)
                    lineOffset = cursor
                } else {
                    pending.append(byte)
                    if pending.count == Self.fragmentLimit {
                        try output(snapshot, partial: true, emit: emit)
                        lineOffset = cursor
                    }
                }
            }
        }
        if final && !pending.isEmpty {
            try output(snapshot, partial: true, emit: emit)
            lineOffset = cursor
        }
    }

    private func output(_ snapshot: SessionSnapshot, partial: Bool, emit: (StreamLine) throws -> Void) throws {
        if !partial && pending.last == 0x0D { pending.removeLast() }
        let date = try reader.timestamp(at: lineOffset)
        try emit(StreamLine(session: snapshot.metadata.id, offset: lineOffset, receivedAt: date,
                            message: String(decoding: pending, as: UTF8.self), partial: partial))
        pending.removeAll(keepingCapacity: true)
    }

    private static func tailStart(reader: SessionReader, byteCount: UInt64, count: Int) throws -> UInt64 {
        guard count > 0, byteCount > 0 else { return byteCount }
        var cursor = byteCount
        var found = 0
        // Scan backwards in fixed buffers; no array of all matching line offsets.
        while cursor > 0 {
            let start = cursor > 65536 ? cursor - 65536 : 0
            let bytes = try reader.readBytes(in: start..<cursor)
            for index in bytes.indices.reversed() where bytes[index] == 0x0A {
                let offset = start + UInt64(index)
                if offset == byteCount - 1 { continue }
                found += 1
                if found == count { return offset + 1 }
            }
            cursor = start
        }
        return 0
    }
}

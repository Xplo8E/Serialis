import Foundation
import Darwin

public final class SessionWriter {
    private let directory: URL
    private let rawURL: URL
    private let indexURL: URL
    private let metadataURL: URL
    private let rawHandle: FileHandle
    private let indexHandle: FileHandle
    private let timestampsHandle: FileHandle
    private let encoder = JSONEncoder()

    private var metadata: SessionMetadata
    private var byteCount: UInt64 = 0
    private var rowCount: UInt64 = 0
    private var currentRowLength = 0
    private var hasOpenRow = false
    private var bytesSinceSync = 0
    private var pendingIndexBytes = Data()
    private var isFinished = false

    public init(rootDirectory: URL, startedAt: Date = Date()) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        let id = UUID().uuidString
        directory = try Self.createSessionDirectory(in: rootDirectory, startedAt: startedAt)
        rawURL = SessionFiles.rawURL(in: directory)
        indexURL = SessionFiles.indexURL(in: directory)
        metadataURL = SessionFiles.metadataURL(in: directory)

        manager.createFile(atPath: rawURL.path, contents: nil)
        manager.createFile(atPath: indexURL.path, contents: nil)

        rawHandle = try FileHandle(forWritingTo: rawURL)
        indexHandle = try FileHandle(forWritingTo: indexURL)

        let timestampsURL = directory.appendingPathComponent(SessionFiles.timestampsFileName)
        manager.createFile(atPath: timestampsURL.path, contents: nil)
        timestampsHandle = try FileHandle(forWritingTo: timestampsURL)

        metadata = SessionMetadata(
            id: id,
            startedAt: startedAt,
            endedAt: nil,
            totalBytes: 0,
            segments: [],
            events: []
        )
        try flushMetadata()
    }

    private static func createSessionDirectory(in root: URL, startedAt: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = formatter.string(from: startedAt)
        var suffix = 1
        while true {
            let candidate = root.appendingPathComponent(suffix == 1 ? name : "\(name)-\(suffix)", isDirectory: true)
            // Reserve the directory atomically so simultaneous launches cannot
            // open and truncate another session's capture files.
            if mkdir(candidate.path, 0o755) == 0 { return candidate }
            let errorCode = errno
            guard errorCode == EEXIST else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode),
                              userInfo: [NSFilePathErrorKey: candidate.path])
            }
            suffix += 1
        }
    }

    deinit {
        try? rawHandle.close()
        try? indexHandle.close()
        try? timestampsHandle.close()
    }

    public var snapshot: SessionSnapshot {
        SessionSnapshot(
            directory: directory,
            metadata: metadata,
            byteCount: byteCount,
            rowCount: rowCount
        )
    }

    public func beginSegment(device: SerialDevice) throws {
        closeActiveSegment(at: byteCount)
        metadata.segments.append(
            CaptureSegment(
                device: device,
                startOffset: byteCount,
                endOffset: nil,
                startedAt: Date(),
                endedAt: nil
            )
        )
        try flushMetadata()
    }

    public func endSegment(reason: String) throws {
        closeActiveSegment(at: byteCount)
        metadata.events.append(SessionEvent(date: Date(), message: reason))
        try flushMetadata()
    }

    public func recordEvent(_ message: String) throws {
        metadata.events.append(SessionEvent(date: Date(), message: message))
        try flushMetadata()
    }

    public func append(_ data: Data, receivedAt: Date = Date()) throws {
        guard !isFinished else {
            throw SessionStoreError.sessionFinished
        }
        guard !data.isEmpty else { return }

        try rawHandle.seekToEnd()
        try rawHandle.write(contentsOf: data)

        // Each 24-byte record stores a chunk's offset, length, and Mac receive
        // time (Double seconds since 1970), all little-endian. Explicit lengths
        // keep a missing/truncated record from assigning a false time to later bytes.
        var timing = Data()
        for value in [byteCount, UInt64(data.count), receivedAt.timeIntervalSince1970.bitPattern] {
            var encoded = value.littleEndian
            withUnsafeBytes(of: &encoded) { timing.append(contentsOf: $0) }
        }
        try timestampsHandle.write(contentsOf: timing)

        // The raw file is append-only. The index stores only display-row starts,
        // so memory use stays constant even when the capture grows for hours.
        var offset = byteCount
        for byte in data {
            if !hasOpenRow {
                try appendRowStart(offset)
                hasOpenRow = true
            } else if currentRowLength == SessionFiles.maxDisplayRowBytes {
                try appendRowStart(offset)
                currentRowLength = 0
            }

            currentRowLength += 1
            offset += 1

            if byte == 0x0A {
                hasOpenRow = false
                currentRowLength = 0
            }
        }

        byteCount += UInt64(data.count)
        metadata.totalBytes = byteCount
        bytesSinceSync += data.count
        try flushIndexBuffer()

        if bytesSinceSync >= 1024 * 1024 {
            try checkpoint()
        }
    }

    public func checkpoint() throws {
        try flushIndexBuffer()
        try rawHandle.synchronize()
        try indexHandle.synchronize()
        try timestampsHandle.synchronize()
        try flushMetadata()
        bytesSinceSync = 0
    }

    public func finish() throws {
        guard !isFinished else { return }
        closeActiveSegment(at: byteCount)
        metadata.endedAt = Date()
        try checkpoint()
        isFinished = true
    }

    private func appendRowStart(_ offset: UInt64) throws {
        var littleEndian = offset.littleEndian
        pendingIndexBytes.append(Data(bytes: &littleEndian, count: MemoryLayout<UInt64>.size))
        rowCount += 1

        if pendingIndexBytes.count >= 64 * 1024 {
            try flushIndexBuffer()
        }
    }

    private func flushIndexBuffer() throws {
        guard !pendingIndexBytes.isEmpty else { return }
        try indexHandle.write(contentsOf: pendingIndexBytes)
        pendingIndexBytes.removeAll(keepingCapacity: true)
    }

    private func closeActiveSegment(at offset: UInt64) {
        guard let lastIndex = metadata.segments.indices.last,
              metadata.segments[lastIndex].endOffset == nil
        else {
            return
        }
        metadata.segments[lastIndex].endOffset = offset
        metadata.segments[lastIndex].endedAt = Date()
    }

    private func flushMetadata() throws {
        let data = try encoder.encode(metadata)
        try data.write(to: metadataURL, options: [.atomic])
    }
}

import Foundation

public final class SessionWriter {
    private let directory: URL
    private let rawURL: URL
    private let indexURL: URL
    private let metadataURL: URL
    private let rawHandle: FileHandle
    private let indexHandle: FileHandle
    private let encoder = JSONEncoder()

    private var metadata: SessionMetadata
    private var byteCount: UInt64 = 0
    private var rowCount: UInt64 = 0
    private var currentRowLength = 0
    private var hasOpenRow = false
    private var bytesSinceSync = 0
    private var pendingIndexBytes = Data()
    private var isFinished = false

    public init(rootDirectory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        let id = UUID().uuidString
        directory = rootDirectory.appendingPathComponent(id, isDirectory: true)
        rawURL = SessionFiles.rawURL(in: directory)
        indexURL = SessionFiles.indexURL(in: directory)
        metadataURL = SessionFiles.metadataURL(in: directory)

        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        manager.createFile(atPath: rawURL.path, contents: nil)
        manager.createFile(atPath: indexURL.path, contents: nil)

        rawHandle = try FileHandle(forWritingTo: rawURL)
        indexHandle = try FileHandle(forWritingTo: indexURL)

        metadata = SessionMetadata(
            id: id,
            startedAt: Date(),
            endedAt: nil,
            totalBytes: 0,
            segments: [],
            events: []
        )
        try flushMetadata()
    }

    deinit {
        try? rawHandle.close()
        try? indexHandle.close()
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

    public func append(_ data: Data) throws {
        guard !isFinished else {
            throw SessionStoreError.sessionFinished
        }
        guard !data.isEmpty else { return }

        try rawHandle.seekToEnd()
        try rawHandle.write(contentsOf: data)

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

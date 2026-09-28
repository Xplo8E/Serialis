import Darwin
import Foundation

public final class SessionReader {
    private let directory: URL
    private let rawURL: URL
    private let indexURL: URL
    private let rawFD: Int32
    private let indexFD: Int32
    private let timestampsFD: Int32

    public init(directory: URL) throws {
        self.directory = directory
        rawURL = SessionFiles.rawURL(in: directory)
        indexURL = SessionFiles.indexURL(in: directory)

        rawFD = open(rawURL.path, O_RDONLY)
        guard rawFD >= 0 else {
            throw SessionStoreError.invalidSessionDirectory(directory)
        }

        // Older sessions have no timing sidecar and remain readable.
        timestampsFD = open(directory.appendingPathComponent(SessionFiles.timestampsFileName).path, O_RDONLY)
        indexFD = open(indexURL.path, O_RDONLY)
        guard indexFD >= 0 else {
            close(rawFD)
            if timestampsFD >= 0 { close(timestampsFD) }
            throw SessionStoreError.invalidSessionDirectory(directory)
        }
    }

    deinit {
        close(rawFD)
        close(indexFD)
        if timestampsFD >= 0 { close(timestampsFD) }
    }

    public static func loadSnapshot(directory: URL, validateIndex: Bool = true) throws -> SessionSnapshot {
        let metadataURL = SessionFiles.metadataURL(in: directory)
        let indexURL = SessionFiles.indexURL(in: directory)
        let rawURL = SessionFiles.rawURL(in: directory)

        guard FileManager.default.fileExists(atPath: metadataURL.path),
              FileManager.default.fileExists(atPath: rawURL.path),
              FileManager.default.fileExists(atPath: indexURL.path)
        else {
            throw SessionStoreError.invalidSessionDirectory(directory)
        }

        let metadataData = try Data(contentsOf: metadataURL)
        var metadata = try JSONDecoder().decode(SessionMetadata.self, from: metadataData)
        let byteCount = rawURL.fileSize
        metadata.totalBytes = byteCount

        let indexSize = indexURL.fileSize
        guard indexSize % UInt64(MemoryLayout<UInt64>.size) == 0 else {
            throw SessionStoreError.corruptIndex(indexURL)
        }

        let rowCount: UInt64
        if validateIndex {
            try recoverIndexIfNeeded(rawURL: rawURL, indexURL: indexURL, byteCount: byteCount)
            rowCount = try validatedRowCount(rawURL: rawURL, indexURL: indexURL, byteCount: byteCount)
        } else {
            rowCount = indexSize / UInt64(MemoryLayout<UInt64>.size)
        }

        return SessionSnapshot(
            directory: directory,
            metadata: metadata,
            byteCount: byteCount,
            rowCount: rowCount
        )
    }

    public func readRow(_ row: UInt64, snapshot: SessionSnapshot) throws -> LogRow {
        guard row < snapshot.rowCount else {
            throw SessionStoreError.rowOutOfBounds(row)
        }

        let start = try rowOffset(row)
        let end: UInt64
        if row + 1 < snapshot.rowCount {
            end = try rowOffset(row + 1)
        } else {
            end = snapshot.byteCount
        }

        guard end <= snapshot.byteCount,
              start <= end,
              end - start <= UInt64(SessionFiles.maxDisplayRowBytes)
        else {
            throw SessionStoreError.corruptIndex(indexURL)
        }

        return LogRow(receivedAt: try timestamp(at: start), offset: start, data: try readRawBytes(in: start..<end))
    }

    /// Resolve only the chunk containing the row's first byte. Binary search
    /// uses constant memory, including while another process appends to the file.
    public func timestamp(at offset: UInt64) throws -> Date? {
        guard timestampsFD >= 0 else { return nil }
        var info = stat()
        guard fstat(timestampsFD, &info) == 0 else { return nil }
        var low: UInt64 = 0
        var high = UInt64(max(0, info.st_size)) / 24 // Ignore an incomplete final record.
        while low < high {
            let middle = low + (high - low) / 2
            let record = try read(fd: timestampsFD, offset: middle * 24, count: 24, source: "timestamps.idx")
            let values = record.withUnsafeBytes { bytes in
                (0..<3).map { UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 8, as: UInt64.self)) }
            }
            if offset < values[0] {
                high = middle
            } else if offset - values[0] >= values[1] {
                low = middle + 1
            } else {
                let seconds = Double(bitPattern: values[2])
                return seconds.isFinite ? Date(timeIntervalSince1970: seconds) : nil
            }
        }
        return nil
    }

    public func readBytes(in range: Range<UInt64>) throws -> Data {
        let byteCount = try rawByteCount()
        guard range.lowerBound <= range.upperBound,
              range.upperBound <= byteCount
        else {
            throw SessionStoreError.byteRangeOutOfBounds(range)
        }
        return try readRawBytes(in: range)
    }

    public func row(containing offset: UInt64, snapshot: SessionSnapshot) throws -> UInt64 {
        guard snapshot.rowCount > 0 else { return 0 }
        if offset >= snapshot.byteCount {
            return snapshot.rowCount - 1
        }

        var low: UInt64 = 0
        var high = snapshot.rowCount
        while low < high {
            let middle = (low + high) / 2
            let rowStart = try rowOffset(middle)
            if rowStart <= offset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low == 0 ? 0 : low - 1
    }

    public func find(
        _ query: Data,
        from offset: UInt64,
        backwards: Bool,
        snapshot: SessionSnapshot,
        isCancelled: () -> Bool
    ) throws -> Range<UInt64>? {
        guard !query.isEmpty else {
            throw SessionStoreError.invalidQuery
        }
        guard snapshot.byteCount >= UInt64(query.count) else {
            return nil
        }

        if backwards {
            return try findBackwards(query, from: offset, snapshot: snapshot, isCancelled: isCancelled)
        }
        return try findForwards(query, from: offset, snapshot: snapshot, isCancelled: isCancelled)
    }

    /// Reuse the count on navigation, and count only newly completed matches when
    /// capture grows. One match range and two counters keep memory independent of hits.
    public func search(
        _ query: Data,
        previous: SessionSearchResult?,
        backwards: Bool,
        advance: Bool = true,
        snapshot: SessionSnapshot,
        isCancelled: () -> Bool
    ) throws -> SessionSearchResult {
        guard !query.isEmpty else { throw SessionStoreError.invalidQuery }
        let prior = previous.flatMap {
            $0.query == query && $0.directory == snapshot.directory && $0.byteCount <= snapshot.byteCount ? $0 : nil
        }
        let overlap = UInt64(query.count - 1)
        let oldEnd = prior?.byteCount ?? 0
        let countStart = oldEnd > overlap ? oldEnd - overlap : 0
        var total = prior?.total ?? 0
        if prior == nil || oldEnd < snapshot.byteCount {
            total += try countMatches(query, from: countStart, snapshot: snapshot, isCancelled: isCancelled)
        }
        if isCancelled() { throw CancellationError() }

        var match = prior?.match
        var number = prior?.number ?? 0
        if total > 0 && (advance || match == nil) {
            let start: UInt64
            if backwards { start = match.map { $0.lowerBound > 0 ? $0.lowerBound - 1 : snapshot.byteCount } ?? snapshot.byteCount }
            else { start = match.map { $0.lowerBound + 1 } ?? 0 }
            match = try find(query, from: start, backwards: backwards, snapshot: snapshot, isCancelled: isCancelled)
            if match == nil && !isCancelled() {
                match = try find(query, from: backwards ? snapshot.byteCount : 0, backwards: backwards,
                                 snapshot: snapshot, isCancelled: isCancelled)
            }
            if backwards { number = number > 1 ? number - 1 : total }
            else { number = number < total ? number + 1 : 1 }
        }
        if isCancelled() { throw CancellationError() }
        return SessionSearchResult(query: query, directory: snapshot.directory, byteCount: snapshot.byteCount,
                                   total: total, number: number, match: match)
    }

    private func countMatches(_ query: Data, from offset: UInt64, snapshot: SessionSnapshot,
                              isCancelled: () -> Bool) throws -> UInt64 {
        let length = UInt64(query.count)
        guard snapshot.byteCount >= length else { return 0 }
        let candidateEnd = snapshot.byteCount - length + 1
        let chunkSize = UInt64(64 * 1024)
        var cursor = offset
        var count: UInt64 = 0
        while cursor < candidateEnd {
            if isCancelled() { throw CancellationError() }
            let end = min(candidateEnd, cursor + chunkSize)
            // Each chunk owns match starts in [cursor, end). The extra bytes let
            // matches span chunk boundaries without counting any hit twice.
            let data = try readRawBytes(in: cursor..<(end + length - 1))
            var start = data.startIndex
            while let match = data.range(of: query, in: start..<data.endIndex) {
                if isCancelled() { throw CancellationError() }
                guard cursor + UInt64(match.lowerBound) < end else { break }
                count += 1
                start = data.index(after: match.lowerBound) // Include overlapping hits, like find().
            }
            cursor = end
        }
        return count
    }

    private func findForwards(
        _ query: Data,
        from offset: UInt64,
        snapshot: SessionSnapshot,
        isCancelled: () -> Bool
    ) throws -> Range<UInt64>? {
        let queryCount = UInt64(query.count)
        guard offset + queryCount <= snapshot.byteCount else { return nil }

        let chunkSize = max(UInt64(64 * 1024), queryCount)
        let overlap = queryCount - 1
        var cursor = offset

        while cursor < snapshot.byteCount {
            if isCancelled() { return nil }

            let readStart = cursor > overlap ? cursor - overlap : cursor
            let readEnd = min(snapshot.byteCount, cursor + chunkSize)
            let data = try readRawBytes(in: readStart..<readEnd)

            var searchStart = data.startIndex
            while let range = data.range(of: query, in: searchStart..<data.endIndex) {
                let foundStart = readStart + UInt64(range.lowerBound)
                if foundStart >= offset {
                    return foundStart..<(foundStart + queryCount)
                }
                searchStart = data.index(after: range.lowerBound)
            }

            if readEnd == snapshot.byteCount { break }
            cursor = readEnd
        }
        return nil
    }

    private func findBackwards(
        _ query: Data,
        from offset: UInt64,
        snapshot: SessionSnapshot,
        isCancelled: () -> Bool
    ) throws -> Range<UInt64>? {
        let queryCount = UInt64(query.count)
        let maxStart = min(offset, snapshot.byteCount - queryCount)
        let chunkSize = max(UInt64(64 * 1024), queryCount)
        var maxCandidate = maxStart

        while true {
            if isCancelled() { return nil }

            let readStart = maxCandidate + 1 > chunkSize ? maxCandidate + 1 - chunkSize : 0
            let readEnd = min(snapshot.byteCount, maxCandidate + queryCount)
            let data = try readRawBytes(in: readStart..<readEnd)

            if let range = data.range(of: query, options: [.backwards]) {
                let foundStart = readStart + UInt64(range.lowerBound)
                if foundStart <= maxCandidate {
                    return foundStart..<(foundStart + queryCount)
                }
            }

            if readStart == 0 { break }
            maxCandidate = readStart - 1
        }
        return nil
    }

    private func rowOffset(_ row: UInt64) throws -> UInt64 {
        let size = UInt64(MemoryLayout<UInt64>.size)
        let data = try read(fd: indexFD, offset: row * size, count: Int(size), source: indexURL.path)
        return data.withUnsafeBytes { pointer in
            pointer.loadUnaligned(as: UInt64.self).littleEndian
        }
    }

    private func readRawBytes(in range: Range<UInt64>) throws -> Data {
        try read(fd: rawFD, offset: range.lowerBound, count: Int(range.count), source: rawURL.path)
    }

    private func read(fd: Int32, offset: UInt64, count: Int, source: String) throws -> Data {
        guard count > 0 else { return Data() }

        var data = Data(count: count)
        var remaining = count
        var written = 0
        var readOffset = off_t(offset)

        try data.withUnsafeMutableBytes { pointer in
            guard let base = pointer.baseAddress else { return }

            while remaining > 0 {
                let result = pread(fd, base.advanced(by: written), remaining, readOffset)
                if result < 0 {
                    throw SessionStoreError.readFailed("pread failed for \(source): errno \(errno)")
                }
                if result == 0 {
                    throw SessionStoreError.readFailed("Unexpected EOF while reading \(source)")
                }

                remaining -= result
                written += result
                readOffset += off_t(result)
            }
        }
        return data
    }

    private func rawByteCount() throws -> UInt64 {
        var info = stat()
        guard fstat(rawFD, &info) == 0 else {
            throw SessionStoreError.readFailed("fstat failed for \(rawURL.path): errno \(errno)")
        }
        return UInt64(info.st_size)
    }

    private static func recoverIndexIfNeeded(rawURL: URL, indexURL: URL, byteCount: UInt64) throws {
        let entrySize = UInt64(MemoryLayout<UInt64>.size)
        let indexSize = indexURL.fileSize
        guard indexSize % entrySize == 0 else {
            throw SessionStoreError.corruptIndex(indexURL)
        }

        let rawFD = open(rawURL.path, O_RDONLY)
        guard rawFD >= 0 else {
            throw SessionStoreError.invalidSessionDirectory(rawURL.deletingLastPathComponent())
        }
        defer { close(rawFD) }

        let indexReadFD = open(indexURL.path, O_RDONLY)
        guard indexReadFD >= 0 else {
            throw SessionStoreError.invalidSessionDirectory(indexURL.deletingLastPathComponent())
        }
        defer { close(indexReadFD) }

        let rowCount = indexSize / entrySize
        if byteCount == 0 {
            guard rowCount == 0 else { throw SessionStoreError.corruptIndex(indexURL) }
            return
        }

        var scanStart: UInt64 = 0
        let shouldAppendInitialRow = rowCount == 0
        if rowCount > 0 {
            scanStart = try readIndexOffset(fd: indexReadFD, row: rowCount - 1, source: indexURL.path)
            guard scanStart < byteCount else {
                throw SessionStoreError.corruptIndex(indexURL)
            }
            let tailSize = byteCount - scanStart
            if tailSize <= UInt64(SessionFiles.maxDisplayRowBytes) {
                let tail = try readFromFD(rawFD, offset: scanStart, count: Int(tailSize), source: rawURL.path)
                // A healthy final row needs no repair. Avoid copying a large index just to discover that.
                if !tail.dropLast().contains(0x0A) { return }
            }
        }

        let temporaryIndexURL = indexURL.deletingLastPathComponent()
            .appendingPathComponent(".\(indexURL.lastPathComponent).recovery.\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temporaryIndexURL.path, contents: nil)
        let temporaryIndexFD = open(temporaryIndexURL.path, O_WRONLY | O_APPEND)
        guard temporaryIndexFD >= 0 else {
            throw SessionStoreError.invalidSessionDirectory(indexURL.deletingLastPathComponent())
        }
        defer {
            close(temporaryIndexFD)
            try? FileManager.default.removeItem(at: temporaryIndexURL)
        }

        if rowCount > 0 {
            try copyFileBytes(from: indexReadFD, to: temporaryIndexFD, byteCount: indexSize, source: indexURL.path)
        }

        var pendingRecoveredOffsets = Data()
        func appendRecoveredOffset(_ offset: UInt64) throws {
            appendOffset(offset, to: &pendingRecoveredOffsets)
            if pendingRecoveredOffsets.count >= 64 * 1024 {
                try writeAll(fd: temporaryIndexFD, data: pendingRecoveredOffsets, source: temporaryIndexURL.path)
                pendingRecoveredOffsets.removeAll(keepingCapacity: true)
            }
        }

        if shouldAppendInitialRow {
            try appendRecoveredOffset(0)
        }

        // Re-scan the final indexed row and all unindexed raw bytes. This is bounded
        // by a 64 KiB read buffer, and repairs the crash window after raw append.
        var cursor = scanStart
        var hasOpenRow = rowCount > 0 || shouldAppendInitialRow
        var currentRowLength = 0
        let readBufferSize = 64 * 1024

        while cursor < byteCount {
            let count = Int(min(UInt64(readBufferSize), byteCount - cursor))
            let chunk = try readFromFD(rawFD, offset: cursor, count: count, source: rawURL.path)

            for byte in chunk {
                if !hasOpenRow {
                    try appendRecoveredOffset(cursor)
                    hasOpenRow = true
                } else if currentRowLength == SessionFiles.maxDisplayRowBytes {
                    try appendRecoveredOffset(cursor)
                    currentRowLength = 0
                }

                currentRowLength += 1
                cursor += 1

                if byte == 0x0A {
                    hasOpenRow = false
                    currentRowLength = 0
                }
            }
        }

        guard !pendingRecoveredOffsets.isEmpty || temporaryIndexURL.fileSize > indexSize else {
            return
        }

        if !pendingRecoveredOffsets.isEmpty {
            try writeAll(fd: temporaryIndexFD, data: pendingRecoveredOffsets, source: temporaryIndexURL.path)
            pendingRecoveredOffsets.removeAll(keepingCapacity: true)
        }

        guard fsync(temporaryIndexFD) == 0 else {
            throw SessionStoreError.readFailed("fsync failed for \(temporaryIndexURL.path): errno \(errno)")
        }
        _ = try validatedRowCount(rawURL: rawURL, indexURL: temporaryIndexURL, byteCount: byteCount)
        _ = try FileManager.default.replaceItemAt(indexURL, withItemAt: temporaryIndexURL)
    }

    private static func validatedRowCount(rawURL: URL, indexURL: URL, byteCount: UInt64) throws -> UInt64 {
        let entrySize = UInt64(MemoryLayout<UInt64>.size)
        let indexSize = indexURL.fileSize
        guard indexSize % entrySize == 0 else {
            throw SessionStoreError.corruptIndex(indexURL)
        }

        let rowCount = indexSize / entrySize
        guard rowCount > 0 else {
            guard byteCount == 0 else { throw SessionStoreError.corruptIndex(indexURL) }
            return 0
        }

        let indexFD = open(indexURL.path, O_RDONLY)
        guard indexFD >= 0 else {
            throw SessionStoreError.invalidSessionDirectory(indexURL.deletingLastPathComponent())
        }
        defer { close(indexFD) }

        var firstBuffer = Data()
        firstBuffer.reserveCapacity(64 * 1024)
        let firstReadCount = Int(min(indexSize, UInt64(64 * 1024)))
        firstBuffer = try readFromFD(indexFD, offset: 0, count: firstReadCount, source: indexURL.path)
        var firstCursor = 0
        var previous = firstBuffer.withUnsafeBytes { pointer in
            pointer.loadUnaligned(fromByteOffset: firstCursor, as: UInt64.self).littleEndian
        }
        firstCursor += MemoryLayout<UInt64>.size
        guard previous == 0, previous < byteCount else {
            throw SessionStoreError.corruptIndex(indexURL)
        }

        var fileOffset = UInt64(firstBuffer.count)
        var remainingRows = rowCount - 1
        var buffer = firstBuffer
        var cursor = firstCursor

        while remainingRows > 0 {
            if cursor == buffer.count {
                let readCount = Int(min(UInt64(64 * 1024), indexSize - fileOffset))
                buffer = try readFromFD(indexFD, offset: fileOffset, count: readCount, source: indexURL.path)
                fileOffset += UInt64(readCount)
                cursor = 0
            }

            let current = buffer.withUnsafeBytes { pointer in
                pointer.loadUnaligned(fromByteOffset: cursor, as: UInt64.self).littleEndian
            }
            cursor += MemoryLayout<UInt64>.size
            remainingRows -= 1

                guard current > previous,
                      current <= byteCount,
                      current - previous <= UInt64(SessionFiles.maxDisplayRowBytes)
                else {
                    throw SessionStoreError.corruptIndex(indexURL)
                }
                previous = current
        }

        guard byteCount - previous <= UInt64(SessionFiles.maxDisplayRowBytes) else {
            throw SessionStoreError.corruptIndex(indexURL)
        }
        return rowCount
    }

    private static func readIndexOffset(fd: Int32, row: UInt64, source: String) throws -> UInt64 {
        let size = MemoryLayout<UInt64>.size
        let data = try readFromFD(fd, offset: row * UInt64(size), count: size, source: source)
        return data.withUnsafeBytes { pointer in
            pointer.loadUnaligned(as: UInt64.self).littleEndian
        }
    }

    private static func appendOffset(_ offset: UInt64, to data: inout Data) {
        var littleEndian = offset.littleEndian
        data.append(Data(bytes: &littleEndian, count: MemoryLayout<UInt64>.size))
    }

    private static func copyFileBytes(from inputFD: Int32, to outputFD: Int32, byteCount: UInt64, source: String) throws {
        var copied: UInt64 = 0
        while copied < byteCount {
            let readCount = Int(min(UInt64(64 * 1024), byteCount - copied))
            let data = try readFromFD(inputFD, offset: copied, count: readCount, source: source)
            try writeAll(fd: outputFD, data: data, source: source)
            copied += UInt64(readCount)
        }
    }

    private static func writeAll(fd: Int32, data: Data, source: String) throws {
        try data.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { return }
            var written = 0
            while written < data.count {
                let result = Darwin.write(fd, base.advanced(by: written), data.count - written)
                if result < 0 {
                    throw SessionStoreError.readFailed("write failed for \(source): errno \(errno)")
                }
                written += result
            }
        }
    }

    private static func readFromFD(_ fd: Int32, offset: UInt64, count: Int, source: String) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        var remaining = count
        var written = 0
        var readOffset = off_t(offset)

        try data.withUnsafeMutableBytes { pointer in
            guard let base = pointer.baseAddress else { return }
            while remaining > 0 {
                let result = pread(fd, base.advanced(by: written), remaining, readOffset)
                if result < 0 {
                    throw SessionStoreError.readFailed("pread failed for \(source): errno \(errno)")
                }
                if result == 0 {
                    throw SessionStoreError.readFailed("Unexpected EOF while reading \(source)")
                }
                remaining -= result
                written += result
                readOffset += off_t(result)
            }
        }
        return data
    }
}

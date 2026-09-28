import XCTest
@testable import SerialisCore

final class SessionStoreTests: XCTestCase {
    func testDatedDirectoriesAvoidCollisionsAndKeepIndependentCaptures() throws {
        let root = try temporaryRoot()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try SessionWriter(rootDirectory: root, startedAt: start)
        try first.append(Data("original\n".utf8))
        let second = try SessionWriter(rootDirectory: root, startedAt: start)
        let third = try SessionWriter(rootDirectory: root, startedAt: start)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = formatter.string(from: start)
        XCTAssertEqual(first.snapshot.directory.lastPathComponent, name)
        XCTAssertEqual(second.snapshot.directory.lastPathComponent, name + "-2")
        XCTAssertEqual(third.snapshot.directory.lastPathComponent, name + "-3")
        XCTAssertNotNil(UUID(uuidString: first.snapshot.metadata.id))
        XCTAssertNotEqual(first.snapshot.metadata.id, second.snapshot.metadata.id)
        XCTAssertEqual(first.snapshot.metadata.startedAt, start)
        try first.finish()
        try second.finish()
        try third.finish()
        let reader = try SessionReader(directory: first.snapshot.directory)
        XCTAssertEqual(try reader.readRow(0, snapshot: first.snapshot).data, Data("original\n".utf8))

        // Legacy UUID folder names and new names can coexist in the catalog.
        let legacy = root.appendingPathComponent(first.snapshot.metadata.id)
        try FileManager.default.moveItem(at: first.snapshot.directory, to: legacy)
        let sessions = try SessionCatalog.list(rootDirectory: root)
        XCTAssertEqual(sessions.count, 3)
        XCTAssertTrue(sessions.contains { $0.directory.lastPathComponent == legacy.lastPathComponent && $0.metadata.id == first.snapshot.metadata.id }, "Loaded: \(sessions.map { $0.directory.path }); expected: \(legacy.path)")
    }

    func testReceiveTimesSurviveReopenAndSplitLines() throws {
        let writer = try SessionWriter(rootDirectory: temporaryRoot())
        let first = Date(timeIntervalSince1970: 1_800_000_000.125)
        // A clock adjustment must not affect lookup: records are ordered by byte offset.
        let second = first.addingTimeInterval(-10)
        try writer.append(Data("partial".utf8), receivedAt: first)
        try writer.append(Data(" line\nsecond\nthird".utf8), receivedAt: second)
        try writer.finish()
        let snapshot = try SessionReader.loadSnapshot(directory: writer.snapshot.directory)
        let reader = try SessionReader(directory: snapshot.directory)
        XCTAssertEqual(try reader.readRow(0, snapshot: snapshot).receivedAt, first)
        XCTAssertEqual(try reader.readRow(1, snapshot: snapshot).receivedAt, second)
        XCTAssertEqual(try reader.readRow(2, snapshot: snapshot).receivedAt, second)
        XCTAssertEqual(try reader.readBytes(in: 0..<snapshot.byteCount), Data("partial line\nsecond\nthird".utf8))
    }

    func testMissingAndTruncatedTimestampsDoNotInventTimes() throws {
        let writer = try SessionWriter(rootDirectory: temporaryRoot())
        try writer.append(Data("first\n".utf8))
        try writer.append(Data("second\n".utf8))
        try writer.finish()
        let directory = writer.snapshot.directory
        let timingURL = directory.appendingPathComponent(SessionFiles.timestampsFileName)
        let handle = try FileHandle(forWritingTo: timingURL)
        try handle.truncate(atOffset: 30) // One full record and part of the next.
        try handle.close()
        let snapshot = try SessionReader.loadSnapshot(directory: directory)
        let reader = try SessionReader(directory: directory)
        XCTAssertNotNil(try reader.readRow(0, snapshot: snapshot).receivedAt)
        XCTAssertNil(try reader.readRow(1, snapshot: snapshot).receivedAt)
        try FileManager.default.removeItem(at: timingURL)
        let legacyReader = try SessionReader(directory: directory)
        XCTAssertNil(try legacyReader.readRow(0, snapshot: snapshot).receivedAt)
        XCTAssertEqual(try legacyReader.readRow(1, snapshot: snapshot).data, Data("second\n".utf8))
    }

    func testPreservesRawBinaryBytesAndRows() throws {
        let writer = try SessionWriter(rootDirectory: temporaryRoot())
        let bytes = Data([0x00, 0x41, 0xFF, 0x0A, 0x42])

        try writer.append(bytes)
        try writer.finish()

        let snapshot = try SessionReader.loadSnapshot(directory: writer.snapshot.directory)
        let reader = try SessionReader(directory: snapshot.directory)

        XCTAssertEqual(snapshot.byteCount, 5)
        XCTAssertEqual(snapshot.rowCount, 2)
        XCTAssertEqual(try reader.readBytes(in: 0..<snapshot.byteCount), bytes)
        XCTAssertEqual(try reader.readRow(0, snapshot: snapshot).data, Data([0x00, 0x41, 0xFF, 0x0A]))
        XCTAssertEqual(try reader.readRow(1, snapshot: snapshot).data, Data([0x42]))
    }

    func testNewlineBoundariesDoNotCreateTrailingEmptyRow() throws {
        let writer = try SessionWriter(rootDirectory: temporaryRoot())

        try writer.append(Data("one\n".utf8))
        try writer.append(Data("two\nthree".utf8))
        try writer.finish()

        let snapshot = try SessionReader.loadSnapshot(directory: writer.snapshot.directory)
        let reader = try SessionReader(directory: snapshot.directory)

        XCTAssertEqual(snapshot.rowCount, 3)
        XCTAssertEqual(String(decoding: try reader.readRow(0, snapshot: snapshot).data, as: UTF8.self), "one\n")
        XCTAssertEqual(String(decoding: try reader.readRow(1, snapshot: snapshot).data, as: UTF8.self), "two\n")
        XCTAssertEqual(String(decoding: try reader.readRow(2, snapshot: snapshot).data, as: UTF8.self), "three")
    }

    func testSplitsHugeLinesAtSixteenKiBDisplayRows() throws {
        let writer = try SessionWriter(rootDirectory: temporaryRoot())
        let hugeLine = Data(repeating: 0x61, count: 16 * 1024 + 7)

        try writer.append(hugeLine)
        try writer.finish()

        let snapshot = try SessionReader.loadSnapshot(directory: writer.snapshot.directory)
        let reader = try SessionReader(directory: snapshot.directory)

        XCTAssertEqual(snapshot.rowCount, 2)
        XCTAssertEqual(try reader.readRow(0, snapshot: snapshot).data.count, 16 * 1024)
        XCTAssertEqual(try reader.readRow(1, snapshot: snapshot).data.count, 7)
        XCTAssertEqual(try reader.row(containing: UInt64(16 * 1024), snapshot: snapshot), 1)
    }

    func testSearchFindsAcrossChunkBoundaryBothDirections() throws {
        let writer = try SessionWriter(rootDirectory: temporaryRoot())
        var data = Data(repeating: 0x78, count: 64 * 1024 - 2)
        data.append(contentsOf: [0x41, 0x42, 0x43, 0x44])
        data.append(Data(repeating: 0x79, count: 4096))

        try writer.append(data)
        try writer.finish()

        let snapshot = try SessionReader.loadSnapshot(directory: writer.snapshot.directory)
        let reader = try SessionReader(directory: snapshot.directory)
        let query = Data("ABCD".utf8)
        let expectedStart = UInt64(64 * 1024 - 2)

        XCTAssertEqual(
            try reader.find(query, from: 0, backwards: false, snapshot: snapshot, isCancelled: { false }),
            expectedStart..<(expectedStart + 4)
        )
        XCTAssertEqual(
            try reader.find(query, from: snapshot.byteCount, backwards: true, snapshot: snapshot, isCancelled: { false }),
            expectedStart..<(expectedStart + 4)
        )
    }

    func testForwardSearchSkipsOverlapHitAndFindsLaterValidMatch() throws {
        let writer = try SessionWriter(rootDirectory: temporaryRoot())
        var data = Data("needle".utf8)
        data.append(Data(repeating: 0x78, count: 64 * 1024 - data.count))
        let secondStart = UInt64(data.count)
        data.append(Data("needle".utf8))

        try writer.append(data)
        try writer.finish()

        let snapshot = try SessionReader.loadSnapshot(directory: writer.snapshot.directory)
        let reader = try SessionReader(directory: snapshot.directory)
        let query = Data("needle".utf8)

        XCTAssertEqual(
            try reader.find(query, from: 64 * 1024 - 2, backwards: false, snapshot: snapshot, isCancelled: { false }),
            secondStart..<(secondStart + UInt64(query.count))
        )
    }

    func testSearchSupportsQueryLargerThanDefaultChunk() throws {
        let writer = try SessionWriter(rootDirectory: temporaryRoot())
        let query = Data(repeating: 0x51, count: 70 * 1024)
        var data = Data(repeating: 0x41, count: 123)
        let start = UInt64(data.count)
        data.append(query)
        data.append(Data(repeating: 0x42, count: 321))

        try writer.append(data)
        try writer.finish()

        let snapshot = try SessionReader.loadSnapshot(directory: writer.snapshot.directory)
        let reader = try SessionReader(directory: snapshot.directory)

        XCTAssertEqual(
            try reader.find(query, from: 0, backwards: false, snapshot: snapshot, isCancelled: { false }),
            start..<(start + UInt64(query.count))
        )
        XCTAssertEqual(
            try reader.find(query, from: snapshot.byteCount, backwards: true, snapshot: snapshot, isCancelled: { false }),
            start..<(start + UInt64(query.count))
        )
    }

    func testSnapshotRecoversRawBytesWrittenAfterIndexFlush() throws {
        let writer = try SessionWriter(rootDirectory: temporaryRoot())
        try writer.append(Data("one\n".utf8))
        try writer.finish()

        let rawURL = SessionFiles.rawURL(in: writer.snapshot.directory)
        let handle = try FileHandle(forWritingTo: rawURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("two\nthree".utf8))
        try handle.close()

        let snapshot = try SessionReader.loadSnapshot(directory: writer.snapshot.directory)
        let reader = try SessionReader(directory: snapshot.directory)

        XCTAssertEqual(snapshot.byteCount, 13)
        XCTAssertEqual(snapshot.rowCount, 3)
        XCTAssertEqual(String(decoding: try reader.readRow(0, snapshot: snapshot).data, as: UTF8.self), "one\n")
        XCTAssertEqual(String(decoding: try reader.readRow(1, snapshot: snapshot).data, as: UTF8.self), "two\n")
        XCTAssertEqual(String(decoding: try reader.readRow(2, snapshot: snapshot).data, as: UTF8.self), "three")
    }

    func testSnapshotRecoverySplitsUnindexedHugeTail() throws {
        let writer = try SessionWriter(rootDirectory: temporaryRoot())
        try writer.append(Data("head\n".utf8))
        try writer.finish()

        let rawURL = SessionFiles.rawURL(in: writer.snapshot.directory)
        let handle = try FileHandle(forWritingTo: rawURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0x61, count: 16 * 1024 + 3))
        try handle.close()

        let snapshot = try SessionReader.loadSnapshot(directory: writer.snapshot.directory)
        let reader = try SessionReader(directory: snapshot.directory)

        XCTAssertEqual(snapshot.rowCount, 3)
        XCTAssertEqual(try reader.readRow(1, snapshot: snapshot).data.count, 16 * 1024)
        XCTAssertEqual(try reader.readRow(2, snapshot: snapshot).data.count, 3)
    }

    func testSnapshotRecoveryFlushesLargeRecoveredIndexInChunks() throws {
        let writer = try SessionWriter(rootDirectory: temporaryRoot())
        try writer.finish()

        let newlineCount = 80 * 1024 + 3
        let rawURL = SessionFiles.rawURL(in: writer.snapshot.directory)
        let handle = try FileHandle(forWritingTo: rawURL)
        try handle.write(contentsOf: Data(repeating: 0x0A, count: newlineCount))
        try handle.close()

        let snapshot = try SessionReader.loadSnapshot(directory: writer.snapshot.directory)
        let reader = try SessionReader(directory: snapshot.directory)

        XCTAssertEqual(snapshot.byteCount, UInt64(newlineCount))
        XCTAssertEqual(snapshot.rowCount, UInt64(newlineCount))
        XCTAssertEqual(SessionFiles.indexURL(in: snapshot.directory).fileSize, UInt64(newlineCount * MemoryLayout<UInt64>.size))
        XCTAssertEqual(try reader.readRow(0, snapshot: snapshot).data, Data([0x0A]))
        XCTAssertEqual(try reader.readRow(UInt64(newlineCount - 1), snapshot: snapshot).data, Data([0x0A]))
    }

    func testCatalogSnapshotDoesNotRecoverIndexOnStartupPath() throws {
        let root = try temporaryRoot()
        let writer = try SessionWriter(rootDirectory: root)
        try writer.append(Data("one\n".utf8))
        try writer.finish()

        let rawURL = SessionFiles.rawURL(in: writer.snapshot.directory)
        let handle = try FileHandle(forWritingTo: rawURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("two\n".utf8))
        try handle.close()

        let listed = try SessionCatalog.list(rootDirectory: root)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].byteCount, 8)
        XCTAssertEqual(listed[0].rowCount, 1)

        let validated = try SessionReader.loadSnapshot(directory: writer.snapshot.directory)
        XCTAssertEqual(validated.rowCount, 2)
    }

    func testSnapshotRejectsCorruptIndexBeforeHugeReadAllocation() throws {
        let writer = try SessionWriter(rootDirectory: temporaryRoot())
        try writer.append(Data(repeating: 0x61, count: 20 * 1024))
        try writer.finish()

        let indexURL = SessionFiles.indexURL(in: writer.snapshot.directory)
        var offsets = Data()
        appendOffset(0, to: &offsets)
        appendOffset(UInt64(17 * 1024), to: &offsets)
        try offsets.write(to: indexURL, options: [.atomic])

        XCTAssertThrowsError(try SessionReader.loadSnapshot(directory: writer.snapshot.directory))
    }

    func testAppendAfterFinishThrows() throws {
        let writer = try SessionWriter(rootDirectory: temporaryRoot())
        try writer.append(Data("done\n".utf8))
        try writer.finish()

        XCTAssertThrowsError(try writer.append(Data("late\n".utf8))) { error in
            guard case SessionStoreError.sessionFinished = error else {
                return XCTFail("Expected sessionFinished, got \(error)")
            }
        }
    }

    func testMetadataSegmentsEventsAndCatalog() throws {
        let root = try temporaryRoot()
        let device = SerialDevice(
            path: "/dev/cu.usbmodem11101",
            vendorID: 0x2E8A,
            productID: 0x00B7,
            manufacturer: "B4",
            product: "B4 PICO Ultra CDC",
            serialNumber: "99EA21A8E17CD666",
            interfaceNumber: 3
        )
        let writer = try SessionWriter(rootDirectory: root)

        try writer.beginSegment(device: device)
        try writer.append(Data("boot\n".utf8))
        try writer.endSegment(reason: "disconnected")
        try writer.recordEvent("manual note")
        try writer.finish()

        let listed = try SessionCatalog.list(rootDirectory: root)

        XCTAssertEqual(device.stableID, "11914:183:B4:B4 PICO Ultra CDC:99EA21A8E17CD666:3")
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].metadata.segments.count, 1)
        XCTAssertEqual(listed[0].metadata.segments[0].startOffset, 0)
        XCTAssertEqual(listed[0].metadata.segments[0].endOffset, 5)
        XCTAssertEqual(listed[0].metadata.events.map(\.message), ["disconnected", "manual note"])
    }

    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SerialisCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func appendOffset(_ offset: UInt64, to data: inout Data) {
        var littleEndian = offset.littleEndian
        data.append(Data(bytes: &littleEndian, count: MemoryLayout<UInt64>.size))
    }
}

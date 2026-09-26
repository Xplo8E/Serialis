import Foundation
import XCTest
@testable import SerialisCore

final class SessionSearchTests: XCTestCase {
    func testNumberedNavigationWrapsBothWays() throws {
        let writer = try fixture(Data("SEP one SEP two SEP".utf8))
        let reader = try SessionReader(directory: writer.snapshot.directory)
        let query = Data("SEP".utf8)
        let first = try reader.search(query, previous: nil, backwards: false, snapshot: writer.snapshot, isCancelled: { false })
        XCTAssertEqual(first.total, 3)
        XCTAssertEqual(first.number, 1)
        XCTAssertEqual(first.match, 0..<3)
        let last = try reader.search(query, previous: first, backwards: true, snapshot: writer.snapshot, isCancelled: { false })
        XCTAssertEqual(last.number, 3)
        XCTAssertEqual(last.match, 16..<19)
        let wrapped = try reader.search(query, previous: last, backwards: false, snapshot: writer.snapshot, isCancelled: { false })
        XCTAssertEqual(wrapped.number, 1)
        XCTAssertEqual(wrapped.match, first.match)
        let second = try reader.search(query, previous: wrapped, backwards: false, snapshot: writer.snapshot, isCancelled: { false })
        XCTAssertEqual(second.number, 2)
        XCTAssertEqual(second.match, 8..<11)
    }

    func testOverlappingHitsAtChunkBoundaryAreCountedOnce() throws {
        let writer = try fixture(Data(repeating: 0x61, count: 65540))
        let reader = try SessionReader(directory: writer.snapshot.directory)
        let result = try reader.search(Data("aaa".utf8), previous: nil, backwards: true,
                                       snapshot: writer.snapshot, isCancelled: { false })
        XCTAssertEqual(result.total, 65538)
        XCTAssertEqual(result.number, 65538)
        XCTAssertEqual(result.match, 65537..<65540)
    }

    func testAppendCountsCompletedBoundaryHitsAndPreservesSelection() throws {
        let writer = try fixture(Data("SEP SE".utf8))
        let reader = try SessionReader(directory: writer.snapshot.directory)
        let query = Data("SEP".utf8)
        let frozen = writer.snapshot
        let first = try reader.search(query, previous: nil, backwards: false, snapshot: frozen, isCancelled: { false })
        try writer.append(Data("P SEP".utf8))
        let refreshed = try reader.search(query, previous: first, backwards: false, advance: false,
                                          snapshot: writer.snapshot, isCancelled: { false })
        XCTAssertEqual(refreshed.total, 3)
        XCTAssertEqual(refreshed.number, 1)
        XCTAssertEqual(refreshed.match, first.match)
        let second = try reader.search(query, previous: refreshed, backwards: false,
                                       snapshot: writer.snapshot, isCancelled: { false })
        XCTAssertEqual(second.number, 2)
        XCTAssertEqual(second.match, 4..<7)
        let paused = try reader.search(query, previous: second, backwards: false,
                                       snapshot: frozen, isCancelled: { false })
        XCTAssertEqual(paused.total, 1)
        XCTAssertEqual(paused.number, 1)
    }

    func testChangedQueryAndSessionResetTheCount() throws {
        let writer = try fixture(Data("SEP SEP other".utf8))
        let reader = try SessionReader(directory: writer.snapshot.directory)
        let first = try reader.search(Data("SEP".utf8), previous: nil, backwards: true,
                                      snapshot: writer.snapshot, isCancelled: { false })
        let changed = try reader.search(Data("other".utf8), previous: first, backwards: false,
                                        snapshot: writer.snapshot, isCancelled: { false })
        XCTAssertEqual(changed.total, 1)
        XCTAssertEqual(changed.number, 1)
        let other = try fixture(Data("SEP".utf8))
        let otherReader = try SessionReader(directory: other.snapshot.directory)
        let switched = try otherReader.search(Data("SEP".utf8), previous: first, backwards: false,
                                              snapshot: other.snapshot, isCancelled: { false })
        XCTAssertEqual(switched.total, 1)
        XCTAssertEqual(switched.number, 1)
    }

    func testNoMatchesAndCancellationNeverPublishAPartialCount() throws {
        let writer = try fixture(Data(repeating: 0x61, count: 10000))
        let reader = try SessionReader(directory: writer.snapshot.directory)
        let empty = try reader.search(Data("SEP".utf8), previous: nil, backwards: false,
                                      snapshot: writer.snapshot, isCancelled: { false })
        XCTAssertEqual(empty.total, 0)
        XCTAssertEqual(empty.number, 0)
        XCTAssertNil(empty.match)
        var checks = 0
        XCTAssertThrowsError(try reader.search(Data("a".utf8), previous: nil, backwards: false,
                                               snapshot: writer.snapshot, isCancelled: {
            checks += 1
            return checks > 20
        })) { XCTAssertTrue($0 is CancellationError) }
    }

    private func fixture(_ data: Data) throws -> SessionWriter {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Serialis-search-\(UUID().uuidString)")
        let writer = try SessionWriter(rootDirectory: root)
        try writer.append(data)
        return writer
    }
}

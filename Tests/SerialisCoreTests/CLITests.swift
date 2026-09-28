import XCTest
@testable import SerialisCore

final class CLITests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SerialisCLI-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testLiteralOrAndExclusionAndCaseMatching() throws {
        let either = try CLIOptions(arguments: ["-m", "SEP", "-m", "panic", "-M", "heartbeat"])
        XCTAssertTrue(either.includes("SEP ready"))
        XCTAssertTrue(either.includes("kernel panic"))
        XCTAssertFalse(either.includes("SEP heartbeat"))
        XCTAssertFalse(either.includes("sep ready"))
        let both = try CLIOptions(arguments: ["-m", "SEP", "-m", "error", "--match-all", "-i"])
        XCTAssertTrue(both.includes("sep ERROR"))
        XCTAssertFalse(both.includes("SEP ready"))
        let literal = try CLIOptions(arguments: ["-m", "a|b.*"])
        XCTAssertTrue(literal.includes("a|b.*"))
        XCTAssertFalse(literal.includes("abc"))
        XCTAssertEqual(try CLIOptions(arguments: ["--no-follow"]).tail, 100)
        XCTAssertThrowsError(try CLIOptions(arguments: ["--tail", "-1"]))
        XCTAssertThrowsError(try CLIOptions(arguments: ["--match"]))
        XCTAssertThrowsError(try CLIOptions(arguments: ["--unknown"]))
    }

    func testTailAndFollowingPartialLinesWithoutDuplicates() throws {
        let writer = try SessionWriter(rootDirectory: root())
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        try writer.append(Data("one\ntwo\npar".utf8), receivedAt: date)
        let stream = try LogStream(snapshot: writer.snapshot, tail: 2)
        var lines: [StreamLine] = []
        try stream.drain(writer.snapshot) { lines.append($0) }
        XCTAssertEqual(lines.map(\.message), ["two"])
        try writer.append(Data("tial\nend".utf8))
        try stream.drain(writer.snapshot) { lines.append($0) }
        XCTAssertEqual(lines.map(\.message), ["two", "partial"])
        XCTAssertEqual(lines[1].receivedAt, date)
        XCTAssertEqual(lines[1].offset, 8)
        try writer.finish()
        try stream.drain(writer.snapshot, final: true) { lines.append($0) }
        XCTAssertEqual(lines.map(\.message), ["two", "partial", "end"])
        XCTAssertTrue(lines.last!.partial)
        try stream.drain(writer.snapshot, final: true) { lines.append($0) }
        XCTAssertEqual(lines.count, 3)
    }

    func testJoiningMidLineSkipsItsSuffixAndTailCountsLogicalLines() throws {
        let writer = try SessionWriter(rootDirectory: root())
        try writer.append(Data("old partial".utf8))
        let stream = try LogStream(snapshot: writer.snapshot, tail: nil)
        try writer.append(Data(" suffix\nnew\n".utf8))
        var lines: [StreamLine] = []
        try stream.drain(writer.snapshot) { lines.append($0) }
        XCTAssertEqual(lines.map(\.message), ["new"])
        let tail = try LogStream(snapshot: writer.snapshot, tail: 1)
        lines = []
        try tail.drain(writer.snapshot) { lines.append($0) }
        XCTAssertEqual(lines.map(\.message), ["new"])
    }

    func testZeroTailSkipsAnExistingPartialLineButKeepsNewLines() throws {
        let writer = try SessionWriter(rootDirectory: root())
        try writer.append(Data("prefix".utf8))
        let stream = try LogStream(snapshot: writer.snapshot, tail: 0)
        try writer.append(Data("suffix\nnew\n".utf8))
        var lines: [StreamLine] = []
        try stream.drain(writer.snapshot, final: true) { lines.append($0) }
        XCTAssertEqual(lines.map(\.message), ["new"])
        XCTAssertEqual(lines.first?.offset, 13)
        XCTAssertEqual(lines.first?.partial, false)
    }

    func testVeryLongLineIsBoundedAndEmittedAsFragments() throws {
        let writer = try SessionWriter(rootDirectory: root())
        let stream = try LogStream(snapshot: writer.snapshot, tail: nil, newCapture: true)
        try writer.append(Data(repeating: 65, count: 1024 * 1024 + 3))
        var lengths: [Int] = []
        try stream.drain(writer.snapshot, final: true) {
            XCTAssertTrue($0.partial)
            lengths.append($0.message.utf8.count)
        }
        XCTAssertEqual(lengths, [1024 * 1024, 3])
    }

    func testExclusiveOwnershipAndStaleStateCannotBecomeActive() throws {
        let root = try root()
        let store = ActiveCaptureStore(rootDirectory: root)
        var lease = try store.acquire()
        XCTAssertNotNil(lease)
        XCTAssertNil(try store.acquire())
        let writer = try SessionWriter(rootDirectory: root)
        let state = ActiveCapture(token: lease!.token, snapshot: writer.snapshot, status: "Waiting",
                                  device: nil, isError: false, disconnectionCount: 0)
        try store.publish(state, lease: lease!)
        XCTAssertEqual(try store.active()?.token, lease!.token)
        lease = nil
        XCTAssertNil(try store.active())
        let newLease = try XCTUnwrap(store.acquire())
        XCTAssertNotEqual(newLease.token, state.token)
        XCTAssertNil(try store.active(), "A newly acquired lock must not expose the old owner's state")
    }
}

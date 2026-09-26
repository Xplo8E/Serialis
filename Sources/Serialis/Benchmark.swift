import Foundation
import SerialisCore

/// This exercises the same storage code as capture, without opening a USB device.
func runBenchmark() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("benchmark-results", isDirectory: true)
    let writer = try SessionWriter(rootDirectory: root)
    let line = Data("[Serialis benchmark] A fixed-size serial line for bounded storage validation.\n".utf8)
    var chunk = Data()
    while chunk.count < 65536 { chunk.append(line) }
    let target = 1_073_741_824
    let started = Date()
    while writer.snapshot.byteCount < target {
        let remaining = target - Int(writer.snapshot.byteCount)
        try writer.append(remaining < chunk.count ? Data(chunk.prefix(remaining)) : chunk)
    }
    try writer.append(Data("SERIALIS_BENCHMARK_END\n".utf8))
    try writer.finish()
    let snapshot = writer.snapshot
    let reader = try SessionReader(directory: snapshot.directory)
    for i in 0..<1000 {
        let row = UInt64(i) * (snapshot.rowCount - 1) / 999
        _ = try reader.readRow(row, snapshot: snapshot)
    }
    let found = try reader.find(Data("SERIALIS_BENCHMARK_END".utf8), from: 0, backwards: false,
        snapshot: snapshot, isCancelled: { false })
    guard found?.lowerBound == UInt64(target) else { throw CocoaError(.fileReadCorruptFile) }
    print("Bytes: \(snapshot.byteCount)")
    print("Display rows: \(snapshot.rowCount)")
    print("Elapsed seconds: \(Date().timeIntervalSince(started))")
    print("Session: \(snapshot.directory.path)")
    print("Random reads: 1000; full-file search: passed")
}

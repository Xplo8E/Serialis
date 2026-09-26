import Foundation
import Darwin

enum SessionFiles {
    static let rawFileName = "capture.raw"
    static let indexFileName = "rows.idx"
    static let metadataFileName = "metadata.json"
    static let maxDisplayRowBytes = 16 * 1024

    static func rawURL(in directory: URL) -> URL {
        directory.appendingPathComponent(rawFileName)
    }

    static func indexURL(in directory: URL) -> URL {
        directory.appendingPathComponent(indexFileName)
    }

    static func metadataURL(in directory: URL) -> URL {
        directory.appendingPathComponent(metadataFileName)
    }
}

extension FileHandle {
    func writeUInt64LittleEndian(_ value: UInt64) throws {
        var littleEndian = value.littleEndian
        let data = Data(bytes: &littleEndian, count: MemoryLayout<UInt64>.size)
        try write(contentsOf: data)
    }
}

extension URL {
    var fileSize: UInt64 {
        var info = stat()
        guard stat(path, &info) == 0 else {
            return 0
        }
        return UInt64(info.st_size)
    }
}

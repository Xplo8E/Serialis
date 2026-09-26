import Darwin
import Foundation

/// Prevent a second process from recovering indexes that the first process is still writing.
final class AppInstanceLock {
    private let descriptor: Int32

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        descriptor = open(directory.appendingPathComponent(".capture.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw NSError(domain: "Serialis", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "Serialis is already using this sessions folder. Close the other instance first."])
        }
    }

    deinit { close(descriptor) }
}

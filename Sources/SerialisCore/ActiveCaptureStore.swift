import Darwin
import Foundation

/// A small, atomically replaced progress record. Readers never recover or modify
/// an active session's index: these counts describe fully written rows and bytes.
public struct ActiveCapture: Codable {
    public var token: String
    public var pid: Int32
    public var snapshot: SessionSnapshot
    public var status: String
    public var device: SerialDevice?
    public var isError: Bool
    public var disconnectionCount: UInt64
    public var selectedDeviceID: String?
    public var ended: Bool

    public init(token: String, snapshot: SessionSnapshot, status: String, device: SerialDevice?,
                isError: Bool, disconnectionCount: UInt64, ended: Bool = false, selectedDeviceID: String? = nil) {
        self.token = token; self.pid = getpid(); self.snapshot = snapshot
        self.status = status; self.device = device; self.isError = isError
        self.disconnectionCount = disconnectionCount; self.ended = ended
        self.selectedDeviceID = selectedDeviceID
    }
}

public final class CaptureLease {
    public let token = UUID().uuidString
    private let descriptor: Int32
    fileprivate init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) } // The kernel also releases flock on a crash.
}

public final class ActiveCaptureStore {
    private let root: URL
    public init(rootDirectory: URL) { root = rootDirectory }
    private var lockURL: URL { root.appendingPathComponent(".capture.lock") }
    private var stateURL: URL { root.appendingPathComponent(".active.json") }

    public func acquire() throws -> CaptureLease? {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let lease = CaptureLease(descriptor: fd)
        let bytes = Array(lease.token.utf8)
        guard ftruncate(fd, 0) == 0, write(fd, bytes, bytes.count) == bytes.count else {
            throw POSIXError(.EIO)
        }
        return lease
    }

    public func publish(_ state: ActiveCapture, lease: CaptureLease) throws {
        guard state.token == lease.token else { throw POSIXError(.EINVAL) }
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }

    public func lastState() throws -> ActiveCapture? {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        return try JSONDecoder().decode(ActiveCapture.self, from: Data(contentsOf: stateURL))
    }

    public func active() throws -> ActiveCapture? {
        let fd = open(lockURL.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return nil }
        guard errno == EWOULDBLOCK else { throw POSIXError(.EIO) }
        var bytes = [UInt8](repeating: 0, count: 36)
        guard pread(fd, &bytes, bytes.count, 0) == bytes.count,
              let state = try lastState(), !state.ended,
              state.token == String(decoding: bytes, as: UTF8.self),
              kill(state.pid, 0) == 0 else { return nil }
        return state
    }
}

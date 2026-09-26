import Foundation
import Darwin
import SerialisCore

struct CaptureUpdate {
    let snapshot: SessionSnapshot
    let status: String
    let device: SerialDevice?
    let isError: Bool
}

/// All port and file operations live on one queue, separate from AppKit's main thread.
final class CaptureController {
    var onUpdate: ((CaptureUpdate) -> Void)?
    private let queue = DispatchQueue(label: "Serialis.capture", qos: .userInitiated)
    private let writer: SessionWriter
    private var source: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var fd: Int32 = -1
    private var device: SerialDevice?
    private var status = "Waiting for a supported interface"
    private var isError = false
    private var hasUnpublishedBytes = false
    private var lastCheckpoint = Date()
    private var needsCheckpoint = false
    private var storageFailed = false
    private let updateLock = NSLock()
    private var pendingUpdate: CaptureUpdate?
    private var deliveryScheduled = false

    init(rootDirectory: URL) throws { writer = try SessionWriter(rootDirectory: rootDirectory) }

    func start() {
        queue.async { [self] in
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(25))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
            self.publish()
        }
    }

    func connect(_ chosen: SerialDevice) {
        queue.async { [self] in
            guard !self.storageFailed else { return }
            if self.device == chosen, self.fd >= 0 { return }
            self.closePort(reason: "Interface changed")
            do {
                self.status = "Connecting to \(chosen.displayName)"
                self.isError = false
                self.publish()
                try Self.checkPortOwner(chosen.path)
                let descriptor = open(chosen.path, O_RDWR | O_NOCTTY | O_NONBLOCK)
                guard descriptor >= 0 else { throw Self.posixError("Open interface") }
                do {
                    guard ioctl(descriptor, TIOCEXCL) == 0 else { throw Self.posixError("Reserve interface") }
                    var settings = termios()
                    guard tcgetattr(descriptor, &settings) == 0 else { throw Self.posixError("Read serial settings") }
                    cfmakeraw(&settings)
                    settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
                    settings.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CSIZE | CCTS_OFLOW | CRTS_IFLOW)
                    settings.c_cflag |= tcflag_t(CS8)
                    cfsetispeed(&settings, speed_t(B115200))
                    cfsetospeed(&settings, speed_t(B115200))
                    guard tcsetattr(descriptor, TCSANOW, &settings) == 0 else { throw Self.posixError("Set 115200 baud") }
                    // Do not flush the input queue: bytes already waiting are part of the capture.
                    try self.writer.beginSegment(device: chosen)
                } catch {
                    close(descriptor)
                    throw error
                }
                self.fd = descriptor
                self.device = chosen
                let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: self.queue)
                source.setEventHandler { [weak self] in self?.readAvailableBytes() }
                // Dispatch must finish with the old source before its descriptor can be reused.
                source.setCancelHandler { close(descriptor) }
                self.source = source
                source.resume()
                self.status = "Capturing"
                self.publish()
            } catch { self.fail(error) }
        }
    }

    func disconnected() {
        queue.async {
            self.closePort(reason: "Device disconnected")
            self.status = "Disconnected · waiting for selected interface"
            self.publish()
        }
    }

    private func readAvailableBytes() {
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 65536)
        for _ in 0..<4 {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                do {
                    try writer.append(Data(buffer.prefix(count)))
                    hasUnpublishedBytes = true
                    needsCheckpoint = true
                } catch { fail(error, storageFailure: true); return }
            } else if count == 0 {
                closePort(reason: "Serial stream ended")
                status = "Disconnected · waiting for selected interface"
                publish()
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK { return }
            else if errno != EINTR { fail(Self.posixError("Read serial data")); return }
        }
    }

    private func tick() {
        if needsCheckpoint && !storageFailed && Date().timeIntervalSince(lastCheckpoint) >= 1 {
            do { try writer.checkpoint() }
            catch { fail(error, storageFailure: true) }
            needsCheckpoint = false
            lastCheckpoint = Date()
        }
        if hasUnpublishedBytes { hasUnpublishedBytes = false; publish() }
    }

    private func closePort(reason: String) {
        source?.cancel()
        source = nil
        if fd >= 0 {
            fd = -1
            do { try writer.endSegment(reason: reason) }
            catch { status = "Could not finalize capture: \(error.localizedDescription)"; isError = true }
        }
        device = nil
    }

    private func fail(_ error: Error, storageFailure: Bool = false) {
        storageFailed = storageFailed || storageFailure
        closePort(reason: "Capture error: \(error.localizedDescription)")
        isError = true
        status = storageFailed ? "Storage error: \(error.localizedDescription). Restart to create a new session." : error.localizedDescription
        publish()
    }

    private func publish() {
        let update = CaptureUpdate(snapshot: writer.snapshot, status: status, device: device, isError: isError)
        // Keep just the newest snapshot if a modal dialog or slow drawing blocks AppKit.
        updateLock.lock()
        pendingUpdate = update
        let shouldSchedule = !deliveryScheduled
        deliveryScheduled = true
        updateLock.unlock()
        guard shouldSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateLock.lock()
            let newest = self.pendingUpdate
            self.pendingUpdate = nil
            self.deliveryScheduled = false
            self.updateLock.unlock()
            if let newest { self.onUpdate?(newest) }
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            closePort(reason: "App closed")
            do { try writer.finish() }
            catch { NSLog("Serialis could not finalize its session: %@", error.localizedDescription) }
        }
    }

    private static func posixError(_ operation: String) -> NSError {
        let code = errno
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(code)))"])
    }

    private static func checkPortOwner(_ path: String) throws {
        // TIOCEXCL blocks later opens; lsof also catches a terminal that opened the port earlier.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-t", "--", path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return } // Availability is still checked by open/ioctl.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if !data.isEmpty {
            throw NSError(domain: "Serialis", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Interface is in use. Close its connection in the other app, then choose Retry."])
        }
    }
}

import Foundation
import Darwin
import SerialisCore

struct CaptureUpdate {
    let snapshot: SessionSnapshot
    let status: String
    let device: SerialDevice?
    let isError: Bool
    var selectedDeviceID: String? = nil
    var ownerEnded = false
    var disconnectionCount: UInt64 = 0
}

/// All port and file operations live on one queue, separate from AppKit's main thread.
final class CaptureController {
    var onUpdate: ((CaptureUpdate) -> Void)?
    private let queue = DispatchQueue(label: "Serialis.capture", qos: .userInitiated)
    private var writer: SessionWriter?
    private let store: ActiveCaptureStore
    private var lease: CaptureLease?
    let isFollower: Bool
    private var followed: ActiveCapture?
    private var hasFollowerUpdate = false
    private var disconnectionCount: UInt64 = 0
    private var selectedDeviceID: String?
    private var stopped = false
    private let portClosures = DispatchGroup()
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

    init(rootDirectory: URL, selectedDeviceID: String? = nil) throws {
        self.selectedDeviceID = selectedDeviceID
        store = ActiveCaptureStore(rootDirectory: rootDirectory)
        // A new owner publishes its session immediately after taking the lock.
        // Briefly retry startup rather than following a stale or missing record.
        let deadline = Date().addingTimeInterval(5)
        while true {
            lease = try store.acquire()
            if lease != nil { break }
            if let active = try store.active() {
                followed = active
                break
            }
            guard Date() < deadline else {
                throw CLIError("Another Serialis process holds capture but has no active session. Close older Serialis versions and try again.")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        isFollower = lease == nil
        if let lease {
            let writer = try SessionWriter(rootDirectory: rootDirectory)
            self.writer = writer
            let state = ActiveCapture(token: lease.token, snapshot: writer.snapshot, status: status,
                                      device: nil, isError: false, disconnectionCount: 0, selectedDeviceID: selectedDeviceID)
            try store.publish(state, lease: lease)
        }
    }

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
            guard !self.storageFailed, !self.stopped, let writer = self.writer else { return }
            if self.device == chosen, self.fd >= 0 { return }
            self.selectedDeviceID = chosen.stableID
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
                    try writer.beginSegment(device: chosen)
                } catch {
                    close(descriptor)
                    throw error
                }
                self.fd = descriptor
                self.device = chosen
                let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: self.queue)
                source.setEventHandler { [weak self] in self?.readAvailableBytes() }
                // Dispatch must finish with the old source before its descriptor can be reused.
                let closures = self.portClosures
                closures.enter()
                source.setCancelHandler { close(descriptor); closures.leave() }
                self.source = source
                source.resume()
                self.status = "Capturing"
                self.publish()
            } catch { self.fail(error) }
        }
    }

    func disconnected() {
        queue.async {
            guard !self.isFollower, !self.stopped else { return }
            self.closePort(reason: "Device disconnected")
            self.status = "Disconnected · waiting for selected interface"
            self.publish()
        }
    }

    private func readAvailableBytes() {
        guard fd >= 0, let writer else { return }
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
            else if [EIO, ENXIO, ENODEV].contains(errno) {
                closePort(reason: "Device disconnected")
                status = "Disconnected · waiting for selected interface"
                publish()
                return
            } else if errno != EINTR { fail(Self.posixError("Read serial data")); return }
        }
    }

    private func tick() {
        guard !stopped else { return }
        if isFollower { pollOwner(); return }
        guard let writer else { return }
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
            disconnectionCount += 1
            fd = -1
            do { try writer?.endSegment(reason: reason) }
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
        guard let writer, let lease else { return }
        let state = ActiveCapture(token: lease.token, snapshot: writer.snapshot, status: status,
                                  device: device, isError: isError, disconnectionCount: disconnectionCount, selectedDeviceID: selectedDeviceID)
        do { try store.publish(state, lease: lease) }
        catch {
            status = "Cannot publish capture progress: \(error.localizedDescription)"
            isError = true
        }
        deliver(CaptureUpdate(snapshot: writer.snapshot, status: status, device: device,
                              isError: isError, selectedDeviceID: selectedDeviceID, disconnectionCount: disconnectionCount))
    }

    private func pollOwner() {
        guard let previous = followed else { return }
        do {
            if let state = try store.active(), state.token == previous.token {
                let changed = !hasFollowerUpdate || state.snapshot.byteCount != previous.snapshot.byteCount ||
                    state.status != previous.status || state.device != previous.device ||
                    state.isError != previous.isError || state.disconnectionCount != previous.disconnectionCount
                followed = state
                if changed {
                    hasFollowerUpdate = true
                    deliver(CaptureUpdate(snapshot: state.snapshot, status: state.status, device: state.device,
                        isError: state.isError, selectedDeviceID: state.selectedDeviceID,
                        disconnectionCount: state.disconnectionCount))
                }
            } else {
                // A new owner may already have replaced .active.json. The old
                // session has its own files and is no longer being written.
                var final = previous.snapshot
                if let snapshot = try? SessionReader.loadSnapshot(directory: final.directory, validateIndex: false) {
                    final = snapshot
                }
                stopped = true
                timer?.cancel(); timer = nil
                deliver(CaptureUpdate(snapshot: final, status: "Capture owner stopped", device: nil,
                    isError: previous.isError, selectedDeviceID: previous.selectedDeviceID,
                    ownerEnded: true, disconnectionCount: previous.disconnectionCount))
            }
        } catch {
            stopped = true
            timer?.cancel(); timer = nil
            deliver(CaptureUpdate(snapshot: previous.snapshot, status: error.localizedDescription,
                                  device: nil, isError: true, ownerEnded: true))
        }
    }

    private func deliver(_ update: CaptureUpdate) {
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
            stopped = true
            timer?.cancel(); timer = nil
            guard let writer, let lease else { return }
            closePort(reason: "Capture owner closed")
            do {
                try writer.finish()
                try store.publish(ActiveCapture(token: lease.token, snapshot: writer.snapshot,
                    status: "Capture ended", device: nil, isError: isError,
                    disconnectionCount: disconnectionCount, ended: true, selectedDeviceID: selectedDeviceID), lease: lease)
            } catch { NSLog("Serialis could not finalize its session: %@", error.localizedDescription) }
            self.writer = nil
        }
        // Cancellation closes descriptors asynchronously on the capture queue.
        // Keep ownership until every previous port has actually been closed.
        portClosures.wait()
        queue.sync { lease = nil }
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

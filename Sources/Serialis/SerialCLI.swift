import Foundation
import Darwin
import SerialisCore

private let cliHelp = """
Usage: serialis [OPTIONS]

Stream serial logs. Follow the active GUI/CLI capture, or start capture if idle.
Mac receive timestamps and the complete raw capture are saved automatically.

  -h, --help                 Show this help
  -v, --version              Show the GUI's version
      --devices              List supported interfaces and exit
      --device ID            Select the stable ID printed by --devices
      --tail N               Print N recent source lines before following
  -f, --follow               Follow new output (default)
      --no-follow            Print a snapshot and exit (default: last 100 lines)
  -m, --match TEXT            Include literal text; repeat for OR
      --match-all            Require every --match term (AND)
  -M, --unmatch TEXT          Exclude any matching literal text
  -i, --ignore-case          Match case-insensitively
      --no-timestamps       Hide timestamps in text output
      --json                Emit one JSON object per line
  -x, --exit-on-disconnect   Exit when the interface disconnects

Filters affect output only, not saved captures. Status messages go to stderr.
Ctrl+C stops your capture, or only detaches if another process owns it.
Lines exceeding 1 MiB are emitted as partial fragments to bound memory.
"""

func runSerialCLI(arguments: [String]) -> Int32 {
    do {
        let options = try CLIOptions(arguments: arguments)
        if options.help { print(cliHelp); return 0 }
        if options.version { print("Serialis \(AppVersion.string)"); return 0 }
        if options.devices {
            let devices = DeviceDiscovery.connectedDevices()
            for device in devices { print("\(device.stableID)\t\(device.path)\t\(device.displayName)") }
            if devices.isEmpty { fputs("No supported interfaces connected\n", stderr) }
            return 0
        }
        return try CLIRunner(options: options).run()
    } catch {
        fputs("serialis: \(error.localizedDescription)\n", stderr)
        return 1
    }
}

private final class CLIRunner {
    let options: CLIOptions
    let root: URL
    let store: ActiveCaptureStore
    var capture: CaptureController?
    var stream: LogStream?
    var latest: SessionSnapshot?
    var signals: [DispatchSourceSignal] = []
    private let shutdownQueue = DispatchQueue(label: "Serialis.cli.shutdown")
    private var shutdownRequested = false // Accessed only on shutdownQueue.
    var discoveryTimer: Timer?
    var stopped = false
    var exitCode: Int32 = 0
    var selectedID: String?
    var attemptedDevice: SerialDevice?
    var previousDisconnects: UInt64?
    var previousStatus = ""
    let formatter = DateFormatter()
    let jsonFormatter = ISO8601DateFormatter()

    init(options: CLIOptions) {
        self.options = options
        root = SessionLocation.root
        store = ActiveCaptureStore(rootDirectory: root)
        selectedID = options.deviceID
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        jsonFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func run() throws -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        if !options.follow {
            guard let active = try store.active() else { throw CLIError("No active capture") }
            try checkDevice(active.device, snapshot: active.snapshot, selection: active.selectedDeviceID)
            let stream = try LogStream(snapshot: active.snapshot, tail: options.tail)
            try stream.drain(active.snapshot, final: true, emit: output)
            return 0
        }
        // Reject a conflicting device before creating any new capture session.
        if let active = try store.active() { try checkDevice(active.device, snapshot: active.snapshot, selection: active.selectedDeviceID) }
        let capture = try CaptureController(rootDirectory: root, selectedDeviceID: options.deviceID)
        self.capture = capture
        if capture.isFollower, let active = try store.active() {
            try checkDevice(active.device, snapshot: active.snapshot, selection: active.selectedDeviceID)
            latest = active.snapshot
            previousDisconnects = active.disconnectionCount
            stream = try LogStream(snapshot: active.snapshot, tail: options.tail)
            try stream?.drain(active.snapshot, emit: output)
        }
        defer {
            discoveryTimer?.invalidate()
            signals.forEach { $0.cancel() }
            capture.stop()
        }
        capture.onUpdate = { [weak self] update in self?.received(update) }
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: shutdownQueue)
            source.setEventHandler { [weak self] in
                guard let self, !self.shutdownRequested else { return }
                self.shutdownRequested = true
                // Save capture independently of stdout, then let the main loop
                // drain its buffered fragment through the normal shutdown path.
                capture.stop()
                DispatchQueue.main.async { self.stopped = true }
                // A stalled pipe must not trap Ctrl+C forever. Raw capture is
                // already finalized before this bounded output-drain fallback.
                self.shutdownQueue.asyncAfter(deadline: .now() + 2) { exit(0) }
            }
            source.resume()
            signals.append(source)
        }
        if !capture.isFollower { previousDisconnects = 0 }
        capture.start()
        if !capture.isFollower {
            discover()
            discoveryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.discover() }
        } else { status("Following the active Serialis capture") }
        while !stopped { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        capture.stop()
        if let latest {
            // Owner stop flushes metadata and writes its final progress. Followers
            // detach without stopping the owner, but can print their buffered tail.
            let final = try store.lastState()
            var snapshot = latest
            if let final, final.snapshot.metadata.id == latest.metadata.id,
               final.snapshot.byteCount >= latest.byteCount {
                snapshot = final.snapshot
            }
            // Crash recovery can observe more bytes than the last published
            // progress record. Never move that final read boundary backwards.
            try stream?.drain(snapshot, final: true, emit: output)
        }
        return exitCode
    }

    func checkDevice(_ device: SerialDevice?, snapshot: SessionSnapshot, selection: String?) throws {
        guard let requested = options.deviceID else { return }
        let actual = device?.stableID ?? selection ?? snapshot.metadata.segments.last?.device.stableID
        guard actual == requested else {
            throw CLIError("--device conflicts with the active capture. Stop its owner before choosing another interface.")
        }
    }

    func received(_ update: CaptureUpdate) {
        guard !stopped else { return }
        do {
            if capture?.isFollower == true { try checkDevice(update.device, snapshot: update.snapshot, selection: update.selectedDeviceID) }
            if stream == nil {
                if capture?.isFollower == false { status("Saving capture to \(update.snapshot.directory.path)") }
                stream = try LogStream(snapshot: update.snapshot, tail: options.tail, newCapture: capture?.isFollower == false)
            }
            latest = update.snapshot
            try stream?.drain(update.snapshot, final: update.ownerEnded, emit: output)
            status(update.status)
            if capture?.isFollower == false && update.device == nil && !update.isError {
                attemptedDevice = nil
            }
            if update.isError { exitCode = 1; stopped = true }
            if update.ownerEnded { stopped = true }
            if options.exitOnDisconnect, let previousDisconnects,
               update.disconnectionCount > previousDisconnects { stopped = true }
            previousDisconnects = update.disconnectionCount
        } catch { status(error.localizedDescription); exitCode = 1; stopped = true }
    }

    func discover() {
        guard !stopped else { return }
        let devices = DeviceDiscovery.connectedDevices()
        if selectedID == nil {
            if devices.count > 1 {
                status("Multiple interfaces connected. Use --devices, then --device ID.")
                exitCode = 1; stopped = true; return
            }
            selectedID = devices.first?.stableID
        }
        if let device = devices.first(where: { $0.stableID == selectedID }) {
            if attemptedDevice != device { attemptedDevice = device; capture?.connect(device) }
        } else if attemptedDevice != nil {
            attemptedDevice = nil
            capture?.disconnected()
        }
    }

    func status(_ text: String) {
        guard text != previousStatus else { return }
        previousStatus = text
        fputs("serialis: \(text)\n", stderr)
    }

    func output(_ line: StreamLine) throws {
        guard options.includes(line.message) else { return }
        let data: Data
        if options.json {
            let timestamp: Any
            if let date = line.receivedAt { timestamp = jsonFormatter.string(from: date) }
            else { timestamp = NSNull() }
            let object: [String: Any] = ["session": line.session, "offset": line.offset,
                "timestamp": timestamp,
                "message": line.message, "partial": line.partial]
            data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data([0x0A])
        } else {
            let prefix = options.timestamps ? "\(line.receivedAt.map { formatter.string(from: $0) } ?? "—")  " : ""
            // Serial bytes are untrusted terminal input. Keep tabs but escape other
            // control characters (especially ESC); raw files remain byte-exact.
            var safe = ""
            safe.reserveCapacity(line.message.utf8.count)
            for scalar in line.message.unicodeScalars {
                if scalar.value == 9 || (scalar.value >= 32 && !(127...159).contains(scalar.value)) {
                    safe.unicodeScalars.append(scalar)
                } else { safe += String(format: "\\u{%04X}", scalar.value) }
            }
            data = Data((prefix + safe + (line.partial ? " [partial]" : "") + "\n").utf8)
        }
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}

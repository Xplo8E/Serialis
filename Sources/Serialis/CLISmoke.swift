import Foundation
import Darwin
import SerialisCore

/// Exercise the real serial transport and separate CLI processes using a PTY.
/// This never discovers or opens connected USB hardware.
func runCLISmokeTest() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Serialis-cli-smoke-\(UUID())")
    let owner = try CaptureController(rootDirectory: root)
    let follower = try CaptureController(rootDirectory: root)
    guard !owner.isFollower, follower.isFollower else { throw CLIError("Ownership mismatch") }
    var master: Int32 = -1
    var slave: Int32 = -1
    var name = [CChar](repeating: 0, count: 1024)
    guard openpty(&master, &slave, &name, nil, nil) == 0 else { throw CLIError("openpty failed") }
    close(slave)
    defer { close(master); follower.stop(); owner.stop() }
    let device = SerialDevice(path: String(cString: name), vendorID: 0, productID: 0,
        manufacturer: "Fixture", product: "PTY", serialNumber: "test", interfaceNumber: 0)
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    func child(_ arguments: [String]) throws -> (Process, Pipe, Pipe) {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--cli"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["SERIALIS_SESSIONS_DIR"] = root.path
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        try process.run()
        return (process, output, errors)
    }
    let first = try child(["--json", "--tail", "0"])
    let second = try child(["--no-timestamps", "-m", "SEP", "-M", "noise", "--tail", "0"])
    let exitOnDisconnect = try child(["-x", "--json", "--tail", "0"])
    defer {
        for process in [first.0, second.0, exitOnDisconnect.0] where process.isRunning { process.terminate() }
    }
    var failed: Error?
    var ended = false
    var sent = false
    var checkedDisconnect = false
    var followerBytes: UInt64 = 0
    let payload = Data("SEP ready\nnoise SEP\nother\nlast fragment".utf8)
    owner.onUpdate = { update in
        if update.isError { failed = CLIError(update.status) }
        if update.device != nil && !sent {
            sent = true
            // Give both launched CLIs time to attach before delivering the fixture.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                _ = payload.withUnsafeBytes { write(master, $0.baseAddress, $0.count) }
            }
        }
        if update.snapshot.byteCount == payload.count && !checkedDisconnect {
            checkedDisconnect = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                owner.disconnected()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if exitOnDisconnect.0.isRunning { failed = CLIError("-x did not exit on disconnect") }
                    owner.connect(device)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { owner.stop() }
                }
            }
        }
    }
    follower.onUpdate = { update in
        if update.isError { failed = CLIError(update.status) }
        followerBytes = update.snapshot.byteCount
        ended = update.ownerEnded
    }
    owner.start(); follower.start(); owner.connect(device)
    let deadline = Date().addingTimeInterval(12)
    while Date() < deadline && failed == nil && (!ended || first.0.isRunning || second.0.isRunning) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    if let failed { throw failed }
    guard ended, !first.0.isRunning, !second.0.isRunning else { throw CLIError("CLI followers did not finish") }
    guard first.0.terminationStatus == 0, second.0.terminationStatus == 0, exitOnDisconnect.0.terminationStatus == 0 else {
        throw CLIError("CLI exit failure: " + String(decoding: first.2.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
    let jsonData = first.1.fileHandleForReading.readDataToEndOfFile()
    let objects = try jsonData.split(separator: 0x0A).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
    guard objects.count == 4, objects.last?["partial"] as? Bool == true,
          objects.first?["timestamp"] is String, followerBytes == payload.count else {
        throw CLIError("Incorrect JSON/follower output: \(String(decoding: jsonData, as: UTF8.self))")
    }
    let filtered = second.1.fileHandleForReading.readDataToEndOfFile()
    guard String(decoding: filtered, as: UTF8.self) == "SEP ready\n" else { throw CLIError("Filter output mismatch") }
    guard try ActiveCaptureStore(rootDirectory: root).active() == nil else { throw CLIError("Owner lock was not released") }
    print("CLI smoke passed: PTY owner, GUI-controller follower, three CLI processes, disconnect/reconnect, -x, filters, JSON timestamps, final fragment, owner shutdown")
}

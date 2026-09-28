import AppKit
import SerialisCore

let firstArgument = CommandLine.arguments.dropFirst().first

if firstArgument == "--cli" {
    exit(runSerialCLI(arguments: Array(CommandLine.arguments.dropFirst(2))))
} else if firstArgument == "--list-devices" {
    let devices = DeviceDiscovery.connectedDevices()
    for device in devices { print("\(device.path)\t\(device.displayName)\t\(device.stableID)") }
    if devices.isEmpty { print("No supported interfaces connected") }
} else if firstArgument == "--transport-smoke" {
    do { try runTransportSmokeTest() }
    catch { fputs("Transport smoke failed: \(error)\n", stderr); exit(1) }
} else if firstArgument == "--benchmark" {
    do { try runBenchmark() }
    catch { fputs("Benchmark failed: \(error)\n", stderr); exit(1) }
} else if firstArgument == "--cli-smoke" {
    do { try runCLISmokeTest() }
    catch { fputs("CLI smoke failed: \(error)\n", stderr); exit(1) }
} else if let firstArgument, firstArgument != "--ui-smoke", !firstArgument.hasPrefix("-psn_") {
    exit(runSerialCLI(arguments: Array(CommandLine.arguments.dropFirst())))
} else {
    let app = NSApplication.shared
    let delegate = AppController()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}

import AppKit
import SerialisCore

if CommandLine.arguments.contains("--list-devices") {
    let devices = DeviceDiscovery.connectedDevices()
    for device in devices { print("\(device.path)\t\(device.displayName)\t\(device.stableID)") }
    if devices.isEmpty { print("No supported interfaces connected") }
} else if CommandLine.arguments.contains("--transport-smoke") {
    do { try runTransportSmokeTest() }
    catch { fputs("Transport smoke failed: \(error)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--benchmark") {
    do { try runBenchmark() }
    catch { fputs("Benchmark failed: \(error)\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared
    let delegate = AppController()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}

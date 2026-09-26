import Darwin
import Foundation
import SerialisCore

/// A pseudo-terminal exercises the real read source and termios path without USB hardware.
func runTransportSmokeTest() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Serialis-transport-\(UUID().uuidString)")
    var master: Int32 = -1
    var slave: Int32 = -1
    var name = [CChar](repeating: 0, count: 1024)
    guard openpty(&master, &slave, &name, nil, nil) == 0 else { throw CocoaError(.fileReadUnknown) }
    close(slave)
    let device = SerialDevice(path: String(cString: name), vendorID: 0, productID: 0,
        manufacturer: "Test", product: "Pseudo-terminal", serialNumber: "fixture", interfaceNumber: 0)
    let payload = Data([0, 255, 13, 10, 65, 9, 66, 10])
    let controller = try CaptureController(rootDirectory: root)
    var stage = 0
    var finished = false
    controller.onUpdate = { update in
        if update.isError {
            fputs("Transport smoke failed: \(update.status)\n", stderr)
            exit(1)
        }
        if update.status == "Capturing", stage == 0 || stage == 3 {
            stage += 1
            let written = payload.withUnsafeBytes { write(master, $0.baseAddress, $0.count) }
            precondition(written == payload.count)
        }
        if update.snapshot.byteCount == payload.count, stage == 1 {
            stage = 2
            controller.disconnected()
        } else if stage == 2, update.status.hasPrefix("Disconnected") {
            stage = 3
            controller.connect(device)
        }
        if update.snapshot.byteCount == payload.count * 2, stage == 4, !finished {
            finished = true
            controller.stop()
            do {
                let reader = try SessionReader(directory: update.snapshot.directory)
                let bytes = try reader.readBytes(in: 0..<UInt64(payload.count * 2))
                precondition(bytes == payload + payload, "Transport changed raw bytes")
                let saved = try SessionReader.loadSnapshot(directory: update.snapshot.directory)
                precondition(saved.metadata.segments.count == 2)
                precondition(saved.metadata.segments[0].endOffset == UInt64(payload.count))
                precondition(saved.metadata.segments[1].endOffset == UInt64(payload.count * 2))
                print("Transport smoke passed: PTY, 115200/8N1, binary bytes, reconnect, two segments, finalize")
                close(master)
                exit(0)
            } catch { fputs("Transport smoke failed: \(error)\n", stderr); exit(1) }
        }
    }
    controller.start()
    controller.connect(device)
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
        fputs("Transport smoke timed out\n", stderr)
        exit(1)
    }
    RunLoop.main.run()
}

import Foundation
import IOKit
import IOKit.serial
import SerialisCore

/// Discovery never opens a port. USB notifications only trigger a fresh inventory.
final class DeviceDiscovery {
    var onChange: (([SerialDevice]) -> Void)?
    private var notificationPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []

    func start() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            refresh()
            return
        }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for event in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let result = IOServiceAddMatchingNotification(
                port, event, IOServiceMatching(kIOSerialBSDServiceValue),
                { context, iterator in
                    while case let entry = IOIteratorNext(iterator), entry != 0 {
                        IOObjectRelease(entry)
                    }
                    guard let context else { return }
                    Unmanaged<DeviceDiscovery>.fromOpaque(context).takeUnretainedValue().refresh()
                }, context, &iterator
            )
            if result == KERN_SUCCESS {
                iterators.append(iterator)
                // Drain once to arm delivery of subsequent notifications.
                while case let entry = IOIteratorNext(iterator), entry != 0 {
                    IOObjectRelease(entry)
                }
            }
        }
        refresh()
    }

    func refresh() { onChange?(Self.connectedDevices()) }

    static func connectedDevices() -> [SerialDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                IOServiceMatching(kIOSerialBSDServiceValue), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var devices: [SerialDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = property(service, "IOCalloutDevice") as? String else { continue }
            let values = ancestorProperties(service)
            guard let vendor = values["idVendor"] as? NSNumber,
                  let productID = values["idProduct"] as? NSNumber,
                  vendor.uint16Value == 0x2e8a, productID.uint16Value == 0x00b7,
                  let maker = values["USB Vendor Name"] as? String, maker == "B4",
                  let product = values["USB Product Name"] as? String, product == "B4 PICO Ultra CDC",
                  let serial = values["USB Serial Number"] as? String, !serial.isEmpty else { continue }
            devices.append(SerialDevice(path: path, vendorID: vendor.uint16Value,
                productID: productID.uint16Value, manufacturer: maker, product: product,
                serialNumber: serial, interfaceNumber: (values["bInterfaceNumber"] as? NSNumber)?.intValue))
        }
        return devices.sorted { $0.stableID < $1.stableID }
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func ancestorProperties(_ service: io_registry_entry_t) -> [String: Any] {
        let keys = ["idVendor", "idProduct", "USB Vendor Name", "USB Product Name", "USB Serial Number", "bInterfaceNumber"]
        var result: [String: Any] = [:]
        var current = service
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        for _ in 0..<16 {
            for key in keys where result[key] == nil { result[key] = property(current, key) }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            IOObjectRelease(current)
            current = parent
        }
        return result
    }

    deinit {
        iterators.forEach { IOObjectRelease($0) }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
    }
}

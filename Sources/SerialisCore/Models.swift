import Foundation

public struct SerialDevice: Codable, Hashable, Sendable {
    public var path: String
    public var vendorID: UInt16
    public var productID: UInt16
    public var manufacturer: String
    public var product: String
    public var serialNumber: String
    public var interfaceNumber: Int?

    public init(
        path: String,
        vendorID: UInt16,
        productID: UInt16,
        manufacturer: String,
        product: String,
        serialNumber: String,
        interfaceNumber: Int?
    ) {
        self.path = path
        self.vendorID = vendorID
        self.productID = productID
        self.manufacturer = manufacturer
        self.product = product
        self.serialNumber = serialNumber
        self.interfaceNumber = interfaceNumber
    }

    public var stableID: String {
        let interfaceText = interfaceNumber.map(String.init) ?? "none"
        return "\(vendorID):\(productID):\(manufacturer):\(product):\(serialNumber):\(interfaceText)"
    }

    public var displayName: String {
        if serialNumber.isEmpty {
            return "\(product) (\(path))"
        }
        return "\(product) \(serialNumber)"
    }
}

public struct CaptureSegment: Codable, Sendable {
    public var device: SerialDevice
    public var startOffset: UInt64
    public var endOffset: UInt64?
    public var startedAt: Date
    public var endedAt: Date?
}

public struct SessionEvent: Codable, Sendable {
    public var date: Date
    public var message: String
}

public struct SessionMetadata: Codable, Sendable {
    public var id: String
    public var startedAt: Date
    public var endedAt: Date?
    public var totalBytes: UInt64
    public var segments: [CaptureSegment]
    public var events: [SessionEvent]
}

public struct SessionSnapshot: Sendable {
    public var directory: URL
    public var metadata: SessionMetadata
    public var byteCount: UInt64
    public var rowCount: UInt64
}

public struct LogRow: Sendable, Equatable {
    public var offset: UInt64
    public var data: Data
}

public enum SessionStoreError: Error, LocalizedError {
    case invalidSessionDirectory(URL)
    case corruptIndex(URL)
    case rowOutOfBounds(UInt64)
    case byteRangeOutOfBounds(Range<UInt64>)
    case invalidQuery
    case readFailed(String)
    case sessionFinished

    public var errorDescription: String? {
        switch self {
        case .invalidSessionDirectory(let url):
            return "Invalid session directory: \(url.path)"
        case .corruptIndex(let url):
            return "Corrupt row index: \(url.path)"
        case .rowOutOfBounds(let row):
            return "Row out of bounds: \(row)"
        case .byteRangeOutOfBounds(let range):
            return "Byte range out of bounds: \(range)"
        case .invalidQuery:
            return "Search query must not be empty."
        case .readFailed(let message):
            return message
        case .sessionFinished:
            return "Session is already finished."
        }
    }
}

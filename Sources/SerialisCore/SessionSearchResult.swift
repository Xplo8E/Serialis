import Foundation

/// A small search summary, not an array of every match in a potentially huge log.
public struct SessionSearchResult: Sendable {
    public let query: Data
    public let directory: URL
    public let byteCount: UInt64
    public let total: UInt64
    public let number: UInt64
    public let match: Range<UInt64>?
}

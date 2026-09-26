import Foundation

public struct DisplayText: Sendable {
    public let text: String

    private let utf16ToByte: [Int]
    private let byteToUTF16: [Int]

    public init(data: Data) {
        let bytes = Array(data)
        let renderEnd = Self.renderEnd(in: bytes)
        var rendered = ""
        var caretToByte = [0]
        var byteToCaret = Array(repeating: 0, count: bytes.count + 1)

        var byteIndex = 0
        var utf16Index = 0

        while byteIndex < renderEnd {
            let startByte = byteIndex
            let startUTF16 = utf16Index
            let output: String
            let endByte: Int

            if bytes[byteIndex] == 0x09 {
                output = "    "
                endByte = byteIndex + 1
            } else if bytes[byteIndex] == 0x00 {
                output = "␀"
                endByte = byteIndex + 1
            } else if let decoded = Self.decodeUTF8Scalar(bytes, at: byteIndex, limit: renderEnd) {
                output = String(decoded.scalar)
                endByte = decoded.nextIndex
            } else {
                output = "\u{FFFD}"
                endByte = byteIndex + 1
            }

            rendered += output
            let endUTF16 = startUTF16 + output.utf16.count

            // A displayed scalar may span two UTF-16 units, and a tab expands to
            // four spaces while still representing one byte. Interior caret
            // positions clamp to the original byte boundary before that unit.
            if output.utf16.count > 0 {
                for index in (startUTF16 + 1)..<endUTF16 {
                    Self.appendMapping(&caretToByte, until: index, byteOffset: startByte)
                }
                Self.appendMapping(&caretToByte, until: endUTF16, byteOffset: endByte)
            }

            for offset in startByte..<endByte {
                byteToCaret[offset] = startUTF16
            }
            byteToCaret[endByte] = endUTF16

            utf16Index = endUTF16
            byteIndex = endByte
        }

        for offset in renderEnd...bytes.count {
            byteToCaret[offset] = utf16Index
        }

        text = rendered
        utf16ToByte = caretToByte
        byteToUTF16 = byteToCaret
    }

    public func byteOffset(forUTF16Index index: Int) -> Int {
        let clamped = min(max(0, index), utf16ToByte.count - 1)
        return utf16ToByte[clamped]
    }

    public func utf16Index(forByteOffset offset: Int) -> Int {
        let clamped = min(max(0, offset), byteToUTF16.count - 1)
        return byteToUTF16[clamped]
    }

    private static func renderEnd(in bytes: [UInt8]) -> Int {
        var end = bytes.count
        if end > 0, bytes[end - 1] == 0x0A {
            end -= 1
            if end > 0, bytes[end - 1] == 0x0D {
                end -= 1
            }
        } else if end > 0, bytes[end - 1] == 0x0D {
            end -= 1
        }
        return end
    }

    private static func appendMapping(_ mapping: inout [Int], until utf16Index: Int, byteOffset: Int) {
        while mapping.count <= utf16Index {
            mapping.append(byteOffset)
        }
        mapping[utf16Index] = byteOffset
    }

    private static func decodeUTF8Scalar(_ bytes: [UInt8], at index: Int, limit: Int) -> (scalar: UnicodeScalar, nextIndex: Int)? {
        let first = bytes[index]
        if first < 0x80 {
            return (UnicodeScalar(UInt32(first))!, index + 1)
        }

        func continuation(_ offset: Int) -> UInt8? {
            guard index + offset < limit else { return nil }
            let byte = bytes[index + offset]
            return byte >= 0x80 && byte <= 0xBF ? byte : nil
        }

        if first >= 0xC2 && first <= 0xDF, let second = continuation(1) {
            let value = (UInt32(first & 0x1F) << 6) | UInt32(second & 0x3F)
            return UnicodeScalar(value).map { ($0, index + 2) }
        }

        if first >= 0xE0 && first <= 0xEF,
           let second = continuation(1),
           let third = continuation(2) {
            if first == 0xE0, second < 0xA0 { return nil }
            if first == 0xED, second > 0x9F { return nil }
            let value = (UInt32(first & 0x0F) << 12) | (UInt32(second & 0x3F) << 6) | UInt32(third & 0x3F)
            return UnicodeScalar(value).map { ($0, index + 3) }
        }

        if first >= 0xF0 && first <= 0xF4,
           let second = continuation(1),
           let third = continuation(2),
           let fourth = continuation(3) {
            if first == 0xF0, second < 0x90 { return nil }
            if first == 0xF4, second > 0x8F { return nil }
            let value = (UInt32(first & 0x07) << 18)
                | (UInt32(second & 0x3F) << 12)
                | (UInt32(third & 0x3F) << 6)
                | UInt32(fourth & 0x3F)
            return UnicodeScalar(value).map { ($0, index + 4) }
        }

        return nil
    }
}

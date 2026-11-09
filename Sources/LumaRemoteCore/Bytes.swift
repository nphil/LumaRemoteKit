import Foundation

extension Data {
    /// Appends `value` little-endian, the protocol's byte order unless a field says otherwise.
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    /// The little-endian integer at `offset` from the start of this slice.
    func littleEndian<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        var value: T = 0
        let start = startIndex + offset
        Swift.withUnsafeMutableBytes(of: &value) { buffer in
            _ = copyBytes(to: buffer, from: start..<(start + MemoryLayout<T>.size))
        }
        return T(littleEndian: value)
    }

    /// Lowercase hex, two digits per byte.
    public var hexString: String {
        let digits = Array("0123456789abcdef".utf8)
        var text = [UInt8]()
        text.reserveCapacity(count * 2)
        for byte in self {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: text, as: UTF8.self)
    }

    /// Bytes from hex digits of either case; nil for an odd count or any other character.
    public init?(hexString: String) {
        let digits = Array(hexString.utf8)
        guard digits.count.isMultiple(of: 2) else { return nil }
        var bytes = Data(capacity: digits.count / 2)
        var index = 0
        while index < digits.count {
            guard let high = Self.nibble(digits[index]), let low = Self.nibble(digits[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        self = bytes
    }

    private static func nibble(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): digit - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): digit - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

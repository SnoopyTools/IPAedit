import Foundation

extension Data {
    /// Reads a little-endian integer at `offset` (relative to the start of this Data).
    func le<T: FixedWidthInteger>(_ offset: Int, _ type: T.Type = T.self) -> T {
        guard offset >= 0, offset + MemoryLayout<T>.size <= count else { return 0 }
        return withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }

    /// Reads a big-endian integer at `offset` (relative to the start of this Data).
    func be<T: FixedWidthInteger>(_ offset: Int, _ type: T.Type = T.self) -> T {
        guard offset >= 0, offset + MemoryLayout<T>.size <= count else { return 0 }
        return withUnsafeBytes { T(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }

    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    /// Byte at a 0-based position regardless of slice indices.
    func byte(at i: Int) -> UInt8 { self[startIndex + i] }

    /// Sub-range using 0-based offsets, returned as a fresh Data (startIndex 0).
    func sub(_ offset: Int, _ length: Int) -> Data {
        let start = Swift.max(0, Swift.min(offset, count))
        let end = Swift.max(start, Swift.min(offset + length, count))
        return Data(self[(startIndex + start)..<(startIndex + end)])
    }

    /// NUL-terminated C string starting at `offset`.
    func cString(at offset: Int, maxLength: Int = 4096) -> String {
        var bytes: [UInt8] = []
        var i = offset
        while i < count, bytes.count < maxLength {
            let b = byte(at: i)
            if b == 0 { break }
            bytes.append(b)
            i += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    var hexString: String {
        map { String(format: "%02X", $0) }.joined()
    }

    init?(hexString: String) {
        let clean = hexString.filter { $0.isHexDigit }
        guard clean.count % 2 == 0 else { return nil }
        var data = Data(capacity: clean.count / 2)
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let b = UInt8(clean[idx..<next], radix: 16) else { return nil }
            data.append(b)
            idx = next
        }
        self = data
    }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func update(_ crc: UInt32, _ data: Data) -> UInt32 {
        var c = ~crc
        table.withUnsafeBufferPointer { t in
            data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                for b in buf {
                    c = t[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
                }
            }
        }
        return ~c
    }
}

enum ByteFormat {
    static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
    static func size(_ bytes: Int) -> String { size(UInt64(max(0, bytes))) }
}

struct SimpleError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

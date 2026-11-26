import Foundation

/// Streaming ZIP writer that keeps Unix permissions and symlinks (needed for a working IPA).
final class ZipWriter {
    private struct Central {
        var name: Data
        var method: UInt16
        var time: UInt16
        var date: UInt16
        var crc: UInt32
        var compressed: UInt64
        var uncompressed: UInt64
        var offset: UInt64
        var mode: UInt32
        var isDirectory: Bool
    }

    private let handle: FileHandle
    private var entries: [Central] = []
    private var position: UInt64 = 0
    private var closed = false
    let compress: Bool

    init(url: URL, compress: Bool) throws {
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw SimpleError("Could not create \(url.lastPathComponent).")
        }
        handle = try FileHandle(forWritingTo: url)
        self.compress = compress
    }

    deinit { if !closed { try? handle.close() } }

    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        position += UInt64(data.count)
    }

    private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        let year = max(1980, min(2107, c.year ?? 1980))
        let t = ((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2)
        let d = ((year - 1980) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1)
        return (UInt16(truncatingIfNeeded: t), UInt16(truncatingIfNeeded: d))
    }

    private func localHeader(name: Data, method: UInt16, time: UInt16, date: UInt16,
                             crc: UInt32, compressed: UInt32, uncompressed: UInt32) -> Data {
        var h = Data()
        h.appendLE(UInt32(0x0403_4B50))
        h.appendLE(UInt16(20))          // version needed
        h.appendLE(UInt16(0x0800))      // UTF-8 names
        h.appendLE(method)
        h.appendLE(time)
        h.appendLE(date)
        h.appendLE(crc)
        h.appendLE(compressed)
        h.appendLE(uncompressed)
        h.appendLE(UInt16(name.count))
        h.appendLE(UInt16(0))           // extra length
        h.append(name)
        return h
    }

    private func checkLimits() throws {
        if position >= 0xFFFF_FFFF { throw SimpleError("IPA would exceed 4 GB, which this version can't write.") }
        if entries.count >= 0xFFFF { throw SimpleError("Too many files (65535 max).") }
    }

    func addDirectory(path: String, mode: UInt32 = 0o755, modified: Date = Date()) throws {
        try checkLimits()
        let p = path.hasSuffix("/") ? path : path + "/"
        let name = Data(p.utf8)
        let (t, d) = Self.dosDateTime(modified)
        let offset = position
        try write(localHeader(name: name, method: 0, time: t, date: d, crc: 0, compressed: 0, uncompressed: 0))
        entries.append(Central(name: name, method: 0, time: t, date: d, crc: 0, compressed: 0, uncompressed: 0,
                               offset: offset, mode: 0o040000 | (mode & 0o7777), isDirectory: true))
    }

    func addSymlink(path: String, target: String, modified: Date = Date()) throws {
        try checkLimits()
        let name = Data(path.utf8)
        let payload = Data(target.utf8)
        let crc = CRC32.update(0, payload)
        let (t, d) = Self.dosDateTime(modified)
        let offset = position
        try write(localHeader(name: name, method: 0, time: t, date: d, crc: crc,
                              compressed: UInt32(payload.count), uncompressed: UInt32(payload.count)))
        try write(payload)
        entries.append(Central(name: name, method: 0, time: t, date: d, crc: crc,
                               compressed: UInt64(payload.count), uncompressed: UInt64(payload.count),
                               offset: offset, mode: 0o120755, isDirectory: false))
    }

    func addFile(path: String, from url: URL, mode: UInt32 = 0o644, modified: Date = Date(),
                 progress: (Int) -> Void) throws {
        try checkLimits()
        let name = Data(path.utf8)
        let (t, d) = Self.dosDateTime(modified)
        let offset = position
        let method: UInt16 = compress ? 8 : 0

        // Placeholder header, patched after the data is written.
        try write(localHeader(name: name, method: method, time: t, date: d, crc: 0, compressed: 0, uncompressed: 0))

        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }

        var crc: UInt32 = 0
        var uncompressed: UInt64 = 0
        var compressed: UInt64 = 0
        let coder: StreamCoder? = try compress ? StreamCoder(.encode) : nil

        while true {
            let chunk = try input.read(upToCount: 1024 * 1024) ?? Data()
            let last = chunk.isEmpty
            if !chunk.isEmpty {
                crc = CRC32.update(crc, chunk)
                uncompressed += UInt64(chunk.count)
                progress(chunk.count)
            }
            if let coder = coder {
                try coder.process(chunk, finalize: last) { out in
                    try self.write(out)
                    compressed += UInt64(out.count)
                }
            } else if !chunk.isEmpty {
                try write(chunk)
                compressed += UInt64(chunk.count)
            }
            if last { break }
        }

        guard uncompressed < 0xFFFF_FFFF, compressed < 0xFFFF_FFFF else {
            throw SimpleError("\(path) is larger than 4 GB, which this version can't write.")
        }

        // Patch CRC + sizes in the local header.
        var patch = Data()
        patch.appendLE(crc)
        patch.appendLE(UInt32(compressed))
        patch.appendLE(UInt32(uncompressed))
        try handle.seek(toOffset: offset + 14)
        try handle.write(contentsOf: patch)
        try handle.seek(toOffset: position)

        entries.append(Central(name: name, method: method, time: t, date: d, crc: crc,
                               compressed: compressed, uncompressed: uncompressed,
                               offset: offset, mode: 0o100000 | (mode & 0o7777), isDirectory: false))
    }

    func finish() throws {
        try checkLimits()
        let cdStart = position
        var cd = Data()
        for e in entries {
            cd.appendLE(UInt32(0x0201_4B50))
            cd.appendLE(UInt16(0x031E))       // made by: Unix, spec 3.0
            cd.appendLE(UInt16(20))
            cd.appendLE(UInt16(0x0800))
            cd.appendLE(e.method)
            cd.appendLE(e.time)
            cd.appendLE(e.date)
            cd.appendLE(e.crc)
            cd.appendLE(UInt32(e.compressed))
            cd.appendLE(UInt32(e.uncompressed))
            cd.appendLE(UInt16(e.name.count))
            cd.appendLE(UInt16(0))            // extra
            cd.appendLE(UInt16(0))            // comment
            cd.appendLE(UInt16(0))            // disk
            cd.appendLE(UInt16(0))            // internal attrs
            cd.appendLE((e.mode << 16) | (e.isDirectory ? 0x10 : 0))
            cd.appendLE(UInt32(e.offset))
            cd.append(e.name)
            if cd.count > 4 * 1024 * 1024 {
                try write(cd)
                cd.removeAll(keepingCapacity: true)
            }
        }
        try write(cd)
        let cdSize = position - cdStart
        guard position < 0xFFFF_FFFF else { throw SimpleError("IPA would exceed 4 GB.") }

        var end = Data()
        end.appendLE(UInt32(0x0605_4B50))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(entries.count))
        end.appendLE(UInt16(entries.count))
        end.appendLE(UInt32(cdSize))
        end.appendLE(UInt32(cdStart))
        end.appendLE(UInt16(0))
        try write(end)
        try handle.synchronize()
        try handle.close()
        closed = true
    }
}

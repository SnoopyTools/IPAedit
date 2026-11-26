import Foundation

struct ZipEntry {
    var path: String
    var versionMadeBy: UInt16
    var flags: UInt16
    var method: UInt16
    var crc32: UInt32
    var compressedSize: UInt64
    var uncompressedSize: UInt64
    var localHeaderOffset: UInt64
    var externalAttributes: UInt32

    var isDirectory: Bool { path.hasSuffix("/") || (unixMode & 0o170000) == 0o040000 }
    var isSymlink: Bool { (unixMode & 0o170000) == 0o120000 }

    /// Unix st_mode stored in the upper 16 bits of the external attributes (0 if none).
    var unixMode: UInt32 {
        let host = versionMadeBy >> 8
        // 3 = Unix, 19 = macOS. Many tools also store Unix modes with other host ids.
        let mode = externalAttributes >> 16
        if host == 3 || host == 19 || mode != 0 { return mode }
        return 0
    }
}

/// Minimal, streaming ZIP reader (stored + deflate, ZIP64 aware).
final class ZipReader {
    let url: URL
    private let handle: FileHandle
    let fileSize: UInt64

    init(url: URL) throws {
        self.url = url
        let h = try FileHandle(forReadingFrom: url)
        handle = h
        fileSize = try h.seekToEnd()
    }

    deinit { try? handle.close() }

    private func read(at offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: count) ?? Data()
    }

    func entries() throws -> [ZipEntry] {
        guard fileSize >= 22 else { throw SimpleError("Not a valid IPA/ZIP file (too small).") }
        let tailLength = Int(min(fileSize, 65_557))
        let tailStart = fileSize - UInt64(tailLength)
        let tail = try read(at: tailStart, count: tailLength)

        var eocd = -1
        var i = tail.count - 22
        while i >= 0 {
            if tail.le(i, UInt32.self) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw SimpleError("Not a valid IPA/ZIP file (no central directory).") }

        var totalEntries = UInt64(tail.le(eocd + 10, UInt16.self))
        var cdSize = UInt64(tail.le(eocd + 12, UInt32.self))
        var cdOffset = UInt64(tail.le(eocd + 16, UInt32.self))

        if totalEntries == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            // ZIP64 end of central directory locator sits right before the EOCD.
            let locPos = eocd - 20
            if locPos >= 0, tail.le(locPos, UInt32.self) == 0x0706_4B50 {
                let z64Offset = tail.le(locPos + 8, UInt64.self)
                let rec = try read(at: z64Offset, count: 56)
                guard rec.le(0, UInt32.self) == 0x0606_4B50 else {
                    throw SimpleError("Broken ZIP64 directory.")
                }
                totalEntries = rec.le(32, UInt64.self)
                cdSize = rec.le(40, UInt64.self)
                cdOffset = rec.le(48, UInt64.self)
            }
        }

        guard cdOffset + cdSize <= fileSize else { throw SimpleError("Central directory is out of range.") }
        let cd = try read(at: cdOffset, count: Int(cdSize))
        var result: [ZipEntry] = []
        result.reserveCapacity(Int(min(totalEntries, 200_000)))

        var p = 0
        while p + 46 <= cd.count {
            guard cd.le(p, UInt32.self) == 0x0201_4B50 else { break }
            let madeBy = cd.le(p + 4, UInt16.self)
            let flags = cd.le(p + 8, UInt16.self)
            let method = cd.le(p + 10, UInt16.self)
            let crc = cd.le(p + 16, UInt32.self)
            var comp = UInt64(cd.le(p + 20, UInt32.self))
            var uncomp = UInt64(cd.le(p + 24, UInt32.self))
            let nameLen = Int(cd.le(p + 28, UInt16.self))
            let extraLen = Int(cd.le(p + 30, UInt16.self))
            let commentLen = Int(cd.le(p + 32, UInt16.self))
            let external = cd.le(p + 38, UInt32.self)
            var localOffset = UInt64(cd.le(p + 42, UInt32.self))

            let nameData = cd.sub(p + 46, nameLen)
            let name: String
            if flags & 0x0800 != 0 {
                name = String(decoding: nameData, as: UTF8.self)
            } else {
                name = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? ""
            }

            // ZIP64 extended information extra field.
            let extra = cd.sub(p + 46 + nameLen, extraLen)
            var e = 0
            while e + 4 <= extra.count {
                let id = extra.le(e, UInt16.self)
                let size = Int(extra.le(e + 2, UInt16.self))
                if id == 0x0001 {
                    var q = e + 4
                    if uncomp == 0xFFFF_FFFF { uncomp = extra.le(q, UInt64.self); q += 8 }
                    if comp == 0xFFFF_FFFF { comp = extra.le(q, UInt64.self); q += 8 }
                    if localOffset == 0xFFFF_FFFF { localOffset = extra.le(q, UInt64.self); q += 8 }
                }
                e += 4 + size
            }

            result.append(ZipEntry(path: name, versionMadeBy: madeBy, flags: flags, method: method,
                                   crc32: crc, compressedSize: comp, uncompressedSize: uncomp,
                                   localHeaderOffset: localOffset, externalAttributes: external))
            p += 46 + nameLen + extraLen + commentLen
        }
        return result
    }

    /// Offset of the entry's compressed data.
    private func dataOffset(for entry: ZipEntry) throws -> UInt64 {
        let header = try read(at: entry.localHeaderOffset, count: 30)
        guard header.count == 30, header.le(0, UInt32.self) == 0x0403_4B50 else {
            throw SimpleError("Bad local header for \(entry.path).")
        }
        let nameLen = UInt64(header.le(26, UInt16.self))
        let extraLen = UInt64(header.le(28, UInt16.self))
        return entry.localHeaderOffset + 30 + nameLen + extraLen
    }

    /// Streams the decompressed bytes of `entry` into `sink`.
    func readEntry(_ entry: ZipEntry, chunk: Int = 512 * 1024, sink: (Data) throws -> Void) throws {
        guard entry.flags & 0x0001 == 0 else { throw SimpleError("\(entry.path) is encrypted.") }
        let start = try dataOffset(for: entry)
        try handle.seek(toOffset: start)
        var remaining = entry.compressedSize

        switch entry.method {
        case 0:
            while remaining > 0 {
                let n = Int(min(UInt64(chunk), remaining))
                guard let d = try handle.read(upToCount: n), !d.isEmpty else {
                    throw SimpleError("Unexpected end of file in \(entry.path).")
                }
                remaining -= UInt64(d.count)
                try sink(d)
            }
        case 8:
            let coder = try StreamCoder(.decode)
            while remaining > 0 && !coder.finished {
                let n = Int(min(UInt64(chunk), remaining))
                guard let d = try handle.read(upToCount: n), !d.isEmpty else {
                    throw SimpleError("Unexpected end of file in \(entry.path).")
                }
                remaining -= UInt64(d.count)
                try coder.process(d, finalize: remaining == 0, sink: sink)
            }
            if entry.compressedSize == 0 {
                try coder.process(Data(), finalize: true, sink: sink)
            }
        default:
            throw SimpleError("\(entry.path) uses unsupported compression method \(entry.method).")
        }
    }

    func data(for entry: ZipEntry) throws -> Data {
        var out = Data()
        try readEntry(entry) { out.append($0) }
        return out
    }

    /// Extracts `entry` to a file on disk, verifying the CRC.
    func extract(_ entry: ZipEntry, to dest: URL, progress: (Int) -> Void) throws {
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let out = try FileHandle(forWritingTo: dest)
        defer { try? out.close() }
        var crc: UInt32 = 0
        try readEntry(entry) { chunk in
            crc = CRC32.update(crc, chunk)
            try out.write(contentsOf: chunk)
            progress(chunk.count)
        }
        if crc != entry.crc32 {
            throw SimpleError("CRC mismatch in \(entry.path) – the IPA may be damaged.")
        }
    }
}

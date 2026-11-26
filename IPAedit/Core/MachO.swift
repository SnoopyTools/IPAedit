import Foundation

struct MachOSlice: Identifiable {
    let id = UUID()
    var offset: UInt64
    var size: UInt64
    var cpu: String
    var is64: Bool
    var fileType: String
    var flags: [String] = []
    var uuid: String?
    var minOS: String?
    var sdk: String?
    var platform: String?
    var dylibs: [String] = []
    var rpaths: [String] = []
    var installName: String?
    var segments: [String] = []
    var encryption: (offset: UInt32, size: UInt32, cryptid: UInt32)?
    var codeSignature: (offset: UInt32, size: UInt32)?
    var entitlements: String?
    var loadCommandCount: Int = 0
}

enum MachOFile {
    static func isMachO(_ head: Data) -> Bool {
        guard head.count >= 8 else { return false }
        let m = head.le(0, UInt32.self)
        if m == 0xFEED_FACE || m == 0xFEED_FACF { return true }
        let b = head.be(0, UInt32.self)
        if b == 0xCAFE_BABE || b == 0xCAFE_BABF {
            // 0xCAFEBABE is also Java class files; a Mach-O fat header has a small arch count.
            let n = head.be(4, UInt32.self)
            return n > 0 && n < 20
        }
        return false
    }

    static func cpuName(_ type: Int32, _ sub: Int32) -> String {
        let s = sub & 0x00FF_FFFF
        switch UInt32(bitPattern: type) {
        case 0x0100_000C: return s == 2 ? "arm64e" : "arm64"
        case 0x0200_000C: return "arm64_32"
        case 12: return s == 11 ? "armv7s" : (s == 9 ? "armv7" : "arm")
        case 0x0100_0007: return "x86_64"
        case 7: return "i386"
        default: return "cpu \(type)/\(s)"
        }
    }

    static func fileTypeName(_ t: UInt32) -> String {
        switch t {
        case 1: return "Object"
        case 2: return "Executable"
        case 6: return "Dynamic library"
        case 7: return "Dynamic linker"
        case 8: return "Bundle"
        case 10: return "dSYM"
        case 11: return "Kext"
        default: return "Type \(t)"
        }
    }

    static func version(_ v: UInt32) -> String {
        let patch = v & 0xFF
        let base = "\(v >> 16).\((v >> 8) & 0xFF)"
        return patch == 0 ? base : base + ".\(patch)"
    }

    static func platformName(_ p: UInt32) -> String {
        switch p {
        case 1: return "macOS"
        case 2: return "iOS"
        case 3: return "tvOS"
        case 4: return "watchOS"
        case 6: return "Mac Catalyst"
        case 7: return "iOS Simulator"
        case 11: return "visionOS"
        default: return "Platform \(p)"
        }
    }

    static func parse(url: URL) throws -> [MachOSlice] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()

        func read(_ off: UInt64, _ n: Int) throws -> Data {
            try handle.seek(toOffset: off)
            return try handle.read(upToCount: n) ?? Data()
        }

        let head = try read(0, 4096)
        guard isMachO(head) else { throw SimpleError("Not a Mach-O file.") }

        var ranges: [(UInt64, UInt64)] = []
        let bm = head.be(0, UInt32.self)
        if bm == 0xCAFE_BABE || bm == 0xCAFE_BABF {
            let n = Int(head.be(4, UInt32.self))
            let is64 = bm == 0xCAFE_BABF
            let stride = is64 ? 32 : 20
            let table = try read(8, n * stride)
            for i in 0..<n {
                let b = i * stride
                if is64 {
                    ranges.append((table.be(b + 8, UInt64.self), table.be(b + 16, UInt64.self)))
                } else {
                    ranges.append((UInt64(table.be(b + 8, UInt32.self)), UInt64(table.be(b + 12, UInt32.self))))
                }
            }
        } else {
            ranges = [(0, fileSize)]
        }

        return try ranges.map { try parseSlice(offset: $0.0, size: $0.1, read: read) }
    }

    private static func parseSlice(offset: UInt64, size: UInt64, read: (UInt64, Int) throws -> Data) throws -> MachOSlice {
        let hdr = try read(offset, 32)
        let magic = hdr.le(0, UInt32.self)
        let is64 = magic == 0xFEED_FACF
        guard is64 || magic == 0xFEED_FACE else { throw SimpleError("Unsupported slice at offset \(offset).") }
        let cpu = cpuName(hdr.le(4, Int32.self), hdr.le(8, Int32.self))
        let fileType = hdr.le(12, UInt32.self)
        let ncmds = Int(hdr.le(16, UInt32.self))
        let sizeofcmds = Int(hdr.le(20, UInt32.self))
        let flags = hdr.le(24, UInt32.self)
        let headerSize: UInt64 = is64 ? 32 : 28

        var slice = MachOSlice(offset: offset, size: size, cpu: cpu, is64: is64, fileType: fileTypeName(fileType))
        slice.loadCommandCount = ncmds
        let flagNames: [(UInt32, String)] = [(0x1, "NOUNDEFS"), (0x4, "DYLDLINK"), (0x80, "TWOLEVEL"),
                                             (0x200000, "PIE"), (0x800000, "HAS_TLV"), (0x2000000, "APP_EXTENSION_SAFE")]
        slice.flags = flagNames.filter { flags & $0.0 != 0 }.map { $0.1 }

        let cmds = try read(offset + headerSize, min(sizeofcmds, 16 * 1024 * 1024))
        var p = 0
        for _ in 0..<ncmds {
            guard p + 8 <= cmds.count else { break }
            let cmd = cmds.le(p, UInt32.self)
            let cmdsize = Int(cmds.le(p + 4, UInt32.self))
            guard cmdsize >= 8 else { break }
            let c = cmds.sub(p, cmdsize)

            switch cmd {
            case 0x19, 0x1: // LC_SEGMENT_64 / LC_SEGMENT
                let name = c.cString(at: 8, maxLength: 16)
                if cmd == 0x19 {
                    let vmsize = c.le(32, UInt64.self)
                    let filesize = c.le(48, UInt64.self)
                    slice.segments.append("\(name)  vm \(ByteFormat.size(vmsize))  file \(ByteFormat.size(filesize))")
                } else {
                    slice.segments.append("\(name)  vm \(ByteFormat.size(UInt64(c.le(28, UInt32.self))))")
                }
            case 0xC, 0x8000_0018, 0x8000_001F, 0x8000_0023, 0x20: // load / weak / reexport / upward / lazy dylib
                let nameOff = Int(c.le(8, UInt32.self))
                var name = c.cString(at: nameOff)
                if cmd == 0x8000_0018 { name += "  (weak)" }
                if cmd == 0x8000_001F { name += "  (re-export)" }
                slice.dylibs.append(name)
            case 0xD: // LC_ID_DYLIB
                slice.installName = c.cString(at: Int(c.le(8, UInt32.self)))
            case 0x8000_001C: // LC_RPATH
                slice.rpaths.append(c.cString(at: Int(c.le(8, UInt32.self))))
            case 0x1B: // LC_UUID
                let u = c.sub(8, 16)
                slice.uuid = NSUUID(uuidBytes: [UInt8](u)).uuidString
            case 0x21, 0x2C: // LC_ENCRYPTION_INFO(_64)
                slice.encryption = (c.le(8, UInt32.self), c.le(12, UInt32.self), c.le(16, UInt32.self))
            case 0x1D: // LC_CODE_SIGNATURE
                slice.codeSignature = (c.le(8, UInt32.self), c.le(12, UInt32.self))
            case 0x32: // LC_BUILD_VERSION
                slice.platform = platformName(c.le(8, UInt32.self))
                slice.minOS = version(c.le(12, UInt32.self))
                slice.sdk = version(c.le(16, UInt32.self))
            case 0x25: // LC_VERSION_MIN_IPHONEOS
                slice.platform = "iOS"
                slice.minOS = version(c.le(8, UInt32.self))
                slice.sdk = version(c.le(12, UInt32.self))
            default:
                break
            }
            p += cmdsize
        }

        if let sig = slice.codeSignature, sig.size > 12 {
            let blob = try read(offset + UInt64(sig.offset), Int(min(sig.size, 4 * 1024 * 1024)))
            slice.entitlements = entitlements(fromSuperBlob: blob)
        }
        return slice
    }

    /// Pulls the XML entitlements out of an embedded code signature super blob.
    static func entitlements(fromSuperBlob blob: Data) -> String? {
        guard blob.count >= 12, blob.be(0, UInt32.self) == 0xFADE_0CC0 else { return nil }
        let count = Int(blob.be(8, UInt32.self))
        for i in 0..<min(count, 64) {
            let base = 12 + i * 8
            guard base + 8 <= blob.count else { break }
            let off = Int(blob.be(base + 4, UInt32.self))
            guard off + 8 <= blob.count else { continue }
            if blob.be(off, UInt32.self) == 0xFADE_7171 {
                let len = Int(blob.be(off + 4, UInt32.self))
                let xml = blob.sub(off + 8, len - 8)
                return String(data: xml, encoding: .utf8)
            }
        }
        return nil
    }
}

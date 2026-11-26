import Foundation

/// A fully parsed 64-bit Mach-O slice for the binary inspector: sections,
/// symbols, imports, function boundaries and Objective-C metadata.
final class MachOImage {
    struct Segment {
        var name: String
        var vmaddr: UInt64
        var vmsize: UInt64
        var fileoff: UInt64
        var filesize: UInt64
    }

    struct Section: Identifiable {
        var id: Int
        var segment: String
        var name: String
        var addr: UInt64
        var size: UInt64
        var offset: UInt32
        var flags: UInt32
        var reserved2: UInt32
        var isCode: Bool { flags & 0x8000_0400 != 0 }
        var isZeroFill: Bool { (flags & 0xFF) == 1 || (flags & 0xFF) == 0x0C }
        var fullName: String { "\(segment),\(name)" }
        func contains(_ a: UInt64) -> Bool { a >= addr && a < addr &+ size }
    }

    struct Symbol: Identifiable {
        var id: Int
        var name: String
        var displayName: String
        var address: UInt64
        var isImport: Bool
        var isExternal: Bool
    }

    struct Function: Identifiable {
        var id: UInt64 { address }
        var address: UInt64
        var end: UInt64
        var name: String?
    }

    struct ObjCMethod: Identifiable {
        var id: String { (isClassMethod ? "+" : "-") + name + String(imp) }
        var name: String
        var types: String
        var imp: UInt64
        var isClassMethod: Bool
    }

    struct ObjCIvar: Identifiable {
        var id: String { name }
        var name: String
        var type: String
        var offset: UInt32
    }

    struct ObjCProperty: Identifiable {
        var id: String { name }
        var name: String
        var attributes: String
    }

    struct ObjCClass: Identifiable {
        var id: UInt64 { address }
        var address: UInt64
        var name: String
        var displayName: String
        var superclass: String?
        var category: String?
        var methods: [ObjCMethod]
        var ivars: [ObjCIvar]
        var properties: [ObjCProperty]
        var protocols: [String]
    }

    enum Pointer {
        case null
        case rebase(UInt64)
        case bind(String?)

        var address: UInt64? {
            if case .rebase(let a) = self { return a }
            return nil
        }
    }

    // MARK: Parsed state

    let url: URL
    let cpu: String
    let sliceOffset: UInt64
    private let file: Data
    private let base: Int

    private(set) var segments: [Segment] = []
    private(set) var sections: [Section] = []
    private(set) var symbols: [Symbol] = []
    private(set) var functions: [Function] = []
    private(set) var classes: [ObjCClass] = []
    private(set) var entryPoint: UInt64?
    private(set) var encryption: (offset: UInt32, size: UInt32, cryptid: UInt32)?
    private(set) var textBase: UInt64 = 0

    /// Address → best known name (symbols, ObjC methods, stubs).
    private(set) var names: [UInt64: String] = [:]

    private var chainedFormat: UInt16 = 0
    private var hasChainedFixups = false
    private var imports: [String] = []

    var isEncrypted: Bool { (encryption?.cryptid ?? 0) != 0 }
    var importedSymbols: [Symbol] { symbols.filter { $0.isImport } }
    var definedSymbols: [Symbol] { symbols.filter { !$0.isImport } }

    /// 64-bit slices in a file, as (index, cpu name) pairs, for a slice picker.
    static func slices(of url: URL) throws -> [MachOSlice] {
        try MachOFile.parse(url: url).filter { $0.is64 }
    }

    init(url: URL, slice: MachOSlice) throws {
        self.url = url
        self.cpu = slice.cpu
        self.sliceOffset = slice.offset
        self.file = try Data(contentsOf: url, options: .alwaysMapped)
        self.base = Int(slice.offset)
        guard slice.is64 else { throw SimpleError("Only 64-bit binaries can be inspected.") }
        try parseLoadCommands()
        parseSymbols()
        parseStubs()
        parseObjC()
        buildFunctions()
    }

    // MARK: Raw reads (offsets relative to the slice)

    private func u8(_ o: Int) -> UInt8 {
        let p = base + o
        guard p >= 0, p < file.count else { return 0 }
        return file[file.startIndex + p]
    }
    private func u16(_ o: Int) -> UInt16 { file.le(base + o, UInt16.self) }
    private func u32(_ o: Int) -> UInt32 { file.le(base + o, UInt32.self) }
    private func i32(_ o: Int) -> Int32 { file.le(base + o, Int32.self) }
    private func u64(_ o: Int) -> UInt64 { file.le(base + o, UInt64.self) }
    private func cstr(_ o: Int, max: Int = 1024) -> String {
        guard o >= 0, base + o < file.count else { return "" }
        return file.cString(at: base + o, maxLength: max)
    }

    /// Bytes of the slice from a slice-relative offset.
    func bytes(fileOffset: Int, count: Int) -> Data {
        file.sub(base + fileOffset, count)
    }

    // MARK: Address translation

    func fileOffset(forVM vm: UInt64) -> Int? {
        for s in segments where vm >= s.vmaddr && vm < s.vmaddr &+ s.filesize {
            return Int(s.fileoff + (vm - s.vmaddr))
        }
        return nil
    }

    func section(containing vm: UInt64) -> Section? {
        sections.first { $0.contains(vm) }
    }

    func section(_ seg: String?, _ name: String) -> [Section] {
        sections.filter { $0.name == name && (seg == nil || $0.segment == seg) }
    }

    func cString(atVM vm: UInt64, max: Int = 1024) -> String? {
        guard let o = fileOffset(forVM: vm) else { return nil }
        return cstr(o, max: max)
    }

    private func u32(atVM vm: UInt64) -> UInt32? {
        guard let o = fileOffset(forVM: vm) else { return nil }
        return u32(o)
    }

    private func i32(atVM vm: UInt64) -> Int32? {
        guard let o = fileOffset(forVM: vm) else { return nil }
        return i32(o)
    }

    /// Reads and decodes a pointer, following chained-fixup encodings.
    func pointer(atVM vm: UInt64) -> Pointer {
        guard let o = fileOffset(forVM: vm) else { return .null }
        return decode(u64(o))
    }

    func decode(_ raw: UInt64) -> Pointer {
        if raw == 0 { return .null }
        guard hasChainedFixups else { return .rebase(raw) }
        let isARM64E = chainedFormat == 1 || chainedFormat == 12 || chainedFormat == 15
        if isARM64E {
            let auth = raw >> 63 == 1
            let bind = (raw >> 62) & 1 == 1
            if bind {
                let ord = Int(chainedFormat == 15 ? raw & 0xFF_FFFF : raw & 0xFFFF)
                return .bind(ord < imports.count ? imports[ord] : nil)
            }
            if auth { return .rebase(textBase &+ (raw & 0xFFFF_FFFF)) }
            var t = raw & 0x7FF_FFFF_FFFF
            if t < textBase { t &+= textBase }
            return .rebase(t)
        } else {
            if raw >> 63 == 1 {
                let ord = Int(raw & 0xFF_FFFF)
                return .bind(ord < imports.count ? imports[ord] : nil)
            }
            var t = raw & 0xF_FFFF_FFFF
            if t < textBase { t &+= textBase }
            return .rebase(t)
        }
    }

    // MARK: Load commands

    private var symtab: (symoff: Int, nsyms: Int, stroff: Int, strsize: Int)?
    private var functionStarts: (off: Int, size: Int)?

    private func parseLoadCommands() throws {
        guard u32(0) == 0xFEED_FACF else { throw SimpleError("Not a 64-bit Mach-O slice.") }
        let ncmds = Int(u32(16))
        var p = 32
        var chained: (off: Int, size: Int)?
        var mainOff: UInt64?
        for _ in 0..<ncmds {
            let cmd = u32(p)
            let size = Int(u32(p + 4))
            guard size >= 8 else { break }
            switch cmd {
            case 0x19: // LC_SEGMENT_64
                let seg = Segment(name: cstr(p + 8, max: 16), vmaddr: u64(p + 24), vmsize: u64(p + 32),
                                  fileoff: u64(p + 40), filesize: u64(p + 48))
                segments.append(seg)
                if seg.name == "__TEXT" { textBase = seg.vmaddr }
                let nsects = Int(u32(p + 64))
                for i in 0..<nsects {
                    let s = p + 72 + i * 80
                    sections.append(Section(id: sections.count, segment: cstr(s + 16, max: 16), name: cstr(s, max: 16),
                                            addr: u64(s + 32), size: u64(s + 40), offset: u32(s + 48),
                                            flags: u32(s + 64), reserved2: u32(s + 72)))
                }
            case 0x2: // LC_SYMTAB
                symtab = (Int(u32(p + 8)), Int(u32(p + 12)), Int(u32(p + 16)), Int(u32(p + 20)))
            case 0x26: // LC_FUNCTION_STARTS
                functionStarts = (Int(u32(p + 8)), Int(u32(p + 12)))
            case 0x8000_0034: // LC_DYLD_CHAINED_FIXUPS
                chained = (Int(u32(p + 8)), Int(u32(p + 12)))
            case 0x8000_0028: // LC_MAIN
                mainOff = u64(p + 8)
            case 0x21, 0x2C: // LC_ENCRYPTION_INFO(_64)
                encryption = (u32(p + 8), u32(p + 12), u32(p + 16))
            default:
                break
            }
            p += size
        }
        if let m = mainOff {
            let text = segments.first { $0.name == "__TEXT" }
            entryPoint = (text?.vmaddr ?? 0) &+ m &- (text?.fileoff ?? 0)
        }
        if let c = chained { parseChainedFixups(off: c.off, size: c.size) }
    }

    private func parseChainedFixups(off: Int, size: Int) {
        guard size >= 28 else { return }
        hasChainedFixups = true
        let startsOff = Int(u32(off + 4))
        let importsOff = Int(u32(off + 8))
        let symbolsOff = Int(u32(off + 12))
        let count = Int(u32(off + 16))
        let format = u32(off + 20)

        // Pointer format: taken from the first segment that has fixups.
        let starts = off + startsOff
        let segCount = Int(u32(starts))
        for i in 0..<min(segCount, 64) {
            let segInfo = Int(u32(starts + 4 + i * 4))
            if segInfo != 0 {
                chainedFormat = u16(starts + segInfo + 6)
                break
            }
        }

        let symBase = off + symbolsOff
        var list: [String] = []
        list.reserveCapacity(min(count, 500_000))
        for i in 0..<min(count, 500_000) {
            let nameOff: Int
            switch format {
            case 2: nameOff = Int(u32(off + importsOff + i * 8) >> 9)
            case 3: nameOff = Int(u64(off + importsOff + i * 16) >> 32)
            default: nameOff = Int(u32(off + importsOff + i * 4) >> 9)
            }
            list.append(cstr(symBase + nameOff, max: 512))
        }
        imports = list
    }

    // MARK: Symbols

    private func parseSymbols() {
        var out: [Symbol] = []
        if let st = symtab {
            out.reserveCapacity(min(st.nsyms, 1_000_000))
            for i in 0..<min(st.nsyms, 1_000_000) {
                let e = st.symoff + i * 16
                let strx = Int(u32(e))
                let type = u8(e + 4)
                if type & 0xE0 != 0 { continue } // debugging (stab) entry
                let value = u64(e + 8)
                let name = strx < st.strsize ? cstr(st.stroff + strx, max: 2048) : ""
                if name.isEmpty { continue }
                let kind = type & 0x0E
                let isImport = kind == 0x0
                if !isImport && kind != 0x0E { continue }
                out.append(Symbol(id: out.count, name: name, displayName: SwiftDemangler.display(name),
                                  address: isImport ? 0 : value, isImport: isImport, isExternal: type & 1 != 0))
                if !isImport && value != 0 && names[value] == nil { names[value] = name }
            }
        }
        // Chained-fixup imports aren't always mirrored in the symbol table.
        let known = Set(out.filter { $0.isImport }.map { $0.name })
        for name in Set(imports) where !known.contains(name) && !name.isEmpty {
            out.append(Symbol(id: out.count, name: name, displayName: SwiftDemangler.display(name),
                              address: 0, isImport: true, isExternal: true))
        }
        symbols = out
    }

    // MARK: Stubs

    /// Names `__stubs` entries after the import they jump to, and `__objc_stubs`
    /// entries after the selector they send.
    private func parseStubs() {
        for s in section("__TEXT", "__stubs") + section("__TEXT", "__auth_stubs") {
            let stride = UInt64(s.reserved2 > 0 ? s.reserved2 : 12)
            var a = s.addr
            while a + stride <= s.addr + s.size {
                if let slot = stubTarget(at: a), case .bind(let name?) = pointer(atVM: slot) {
                    names[a] = name
                }
                a += stride
            }
        }
        for s in section("__TEXT", "__objc_stubs") {
            var a = s.addr
            while a + 8 <= s.addr + s.size {
                if let w0 = u32(atVM: a), let w1 = u32(atVM: a + 4),
                   let page = ARM64.adrp(w0, pc: a), ARM64.rd(w0) == 1,
                   let ld = ARM64.ldrX(w1), ld.0 == 1,
                   let sel = selector(atRef: page + ld.1) {
                    names[a] = "objc_msgSend$" + sel
                    a += 32
                } else {
                    a += 4
                }
            }
        }
    }

    private func stubTarget(at a: UInt64) -> UInt64? {
        guard let w0 = u32(atVM: a), let w1 = u32(atVM: a + 4), let page = ARM64.adrp(w0, pc: a) else { return nil }
        if let ld = ARM64.ldrX(w1) { return page + ld.1 }
        if let add = ARM64.addImm(w1) { return page + add.2 }
        return nil
    }

    private func selector(atRef ref: UInt64) -> String? {
        guard let target = pointer(atVM: ref).address else { return nil }
        return cString(atVM: target, max: 512)
    }

    // MARK: Objective-C

    private func parseObjC() {
        var out: [ObjCClass] = []
        var classNameByAddr: [UInt64: String] = [:]

        for s in section(nil, "__objc_classlist") {
            for i in 0..<Int(s.size / 8) {
                guard let cls = pointer(atVM: s.addr + UInt64(i * 8)).address,
                      var c = readClass(at: cls) else { continue }
                classNameByAddr[cls] = c.name
                if case .rebase(let meta) = pointer(atVM: cls), let m = readClass(at: meta, isMeta: true) {
                    c.methods += m.methods
                }
                out.append(c)
            }
        }
        // Superclasses that live in this binary are only nameable once every class is read.
        for i in out.indices {
            if let sup = out[i].superclass, sup.hasPrefix("0x"), let a = UInt64(sup.dropFirst(2), radix: 16) {
                out[i].superclass = classNameByAddr[a].map(SwiftDemangler.display) ?? sup
            }
        }

        for s in section(nil, "__objc_catlist") {
            for i in 0..<Int(s.size / 8) {
                guard let cat = pointer(atVM: s.addr + UInt64(i * 8)).address,
                      let c = readCategory(at: cat, classNames: classNameByAddr) else { continue }
                out.append(c)
            }
        }

        for c in out {
            let owner = c.category.map { "\(c.displayName)(\($0))" } ?? c.displayName
            for m in c.methods where m.imp != 0 {
                names[m.imp] = "\(m.isClassMethod ? "+" : "-")[\(owner) \(m.name)]"
            }
        }
        classes = out.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func readClass(at cls: UInt64, isMeta: Bool = false) -> ObjCClass? {
        guard fileOffset(forVM: cls) != nil else { return nil }
        guard case .rebase(let bits) = pointer(atVM: cls + 32) else { return nil }
        let ro = bits & 0x7FFF_FFFF_FFF8
        guard fileOffset(forVM: ro) != nil else { return nil }
        let name = pointer(atVM: ro + 24).address.flatMap { cString(atVM: $0, max: 512) } ?? "?"

        var superclass: String?
        if !isMeta {
            switch pointer(atVM: cls + 8) {
            case .bind(let n?): superclass = SwiftDemangler.display(Self.stripClassPrefix(n))
            case .rebase(let a): superclass = "0x" + String(a, radix: 16)
            default: break
            }
        }
        let methods = readMethods(pointer(atVM: ro + 32).address, isClassMethod: isMeta)
        let ivars = isMeta ? [] : readIvars(pointer(atVM: ro + 48).address)
        let props = isMeta ? [] : readProperties(pointer(atVM: ro + 64).address)
        let protos = isMeta ? [] : readProtocols(pointer(atVM: ro + 40).address)
        return ObjCClass(address: cls, name: name, displayName: SwiftDemangler.display(name), superclass: superclass,
                         category: nil, methods: methods, ivars: ivars, properties: props, protocols: protos)
    }

    private func readCategory(at cat: UInt64, classNames: [UInt64: String]) -> ObjCClass? {
        guard fileOffset(forVM: cat) != nil else { return nil }
        let catName = pointer(atVM: cat).address.flatMap { cString(atVM: $0, max: 512) } ?? "?"
        var clsName = "?"
        switch pointer(atVM: cat + 8) {
        case .bind(let n?): clsName = Self.stripClassPrefix(n)
        case .rebase(let a): clsName = classNames[a] ?? ("0x" + String(a, radix: 16))
        default: break
        }
        let methods = readMethods(pointer(atVM: cat + 16).address, isClassMethod: false)
            + readMethods(pointer(atVM: cat + 24).address, isClassMethod: true)
        let protos = readProtocols(pointer(atVM: cat + 32).address)
        let props = readProperties(pointer(atVM: cat + 40).address)
        return ObjCClass(address: cat, name: clsName, displayName: SwiftDemangler.display(clsName), superclass: nil,
                         category: catName, methods: methods, ivars: [], properties: props, protocols: protos)
    }

    static func stripClassPrefix(_ n: String) -> String {
        for p in ["_OBJC_CLASS_$_", "_OBJC_METACLASS_$_"] where n.hasPrefix(p) { return String(n.dropFirst(p.count)) }
        return n
    }

    private func readMethods(_ list: UInt64?, isClassMethod: Bool) -> [ObjCMethod] {
        guard let list = list, let flags = u32(atVM: list), let count = u32(atVM: list + 4) else { return [] }
        let relative = flags & 0x8000_0000 != 0
        let entsize = UInt64(flags & 0xFFFC)
        guard entsize >= 12, count < 100_000 else { return [] }
        var out: [ObjCMethod] = []
        for i in 0..<UInt64(count) {
            let e = list + 8 + i * entsize
            if relative {
                guard let n = i32(atVM: e), let t = i32(atVM: e + 4), let m = i32(atVM: e + 8) else { break }
                let selRef = UInt64(bitPattern: Int64(e) + Int64(n))
                let name = selector(atRef: selRef) ?? "?"
                let types = cString(atVM: UInt64(bitPattern: Int64(e + 4) + Int64(t)), max: 512) ?? ""
                let imp = m == 0 ? 0 : UInt64(bitPattern: Int64(e + 8) + Int64(m))
                out.append(ObjCMethod(name: name, types: types, imp: imp, isClassMethod: isClassMethod))
            } else {
                let name = pointer(atVM: e).address.flatMap { cString(atVM: $0, max: 512) } ?? "?"
                let types = pointer(atVM: e + 8).address.flatMap { cString(atVM: $0, max: 512) } ?? ""
                let imp = pointer(atVM: e + 16).address ?? 0
                out.append(ObjCMethod(name: name, types: types, imp: imp, isClassMethod: isClassMethod))
            }
        }
        return out
    }

    private func readIvars(_ list: UInt64?) -> [ObjCIvar] {
        guard let list = list, let entsize = u32(atVM: list), let count = u32(atVM: list + 4),
              entsize >= 24, count < 100_000 else { return [] }
        var out: [ObjCIvar] = []
        for i in 0..<UInt64(count) {
            let e = list + 8 + i * UInt64(entsize)
            let offset = pointer(atVM: e).address.flatMap { u32(atVM: $0) } ?? 0
            let name = pointer(atVM: e + 8).address.flatMap { cString(atVM: $0, max: 512) } ?? "?"
            let type = pointer(atVM: e + 16).address.flatMap { cString(atVM: $0, max: 512) } ?? ""
            out.append(ObjCIvar(name: name, type: type, offset: offset))
        }
        return out
    }

    private func readProperties(_ list: UInt64?) -> [ObjCProperty] {
        guard let list = list, let entsize = u32(atVM: list), let count = u32(atVM: list + 4),
              entsize >= 16, count < 100_000 else { return [] }
        var out: [ObjCProperty] = []
        for i in 0..<UInt64(count) {
            let e = list + 8 + i * UInt64(entsize)
            let name = pointer(atVM: e).address.flatMap { cString(atVM: $0, max: 512) } ?? "?"
            let attrs = pointer(atVM: e + 8).address.flatMap { cString(atVM: $0, max: 1024) } ?? ""
            out.append(ObjCProperty(name: name, attributes: attrs))
        }
        return out
    }

    private func readProtocols(_ list: UInt64?) -> [String] {
        guard let list = list, fileOffset(forVM: list) != nil else { return [] }
        let count = min(u64(fileOffset(forVM: list)!), 1000)
        var out: [String] = []
        for i in 0..<count {
            switch pointer(atVM: list + 8 + i * 8) {
            case .rebase(let p):
                if let n = pointer(atVM: p + 8).address.flatMap({ cString(atVM: $0, max: 512) }) {
                    out.append(SwiftDemangler.display(n))
                }
            case .bind(let n?):
                out.append(n.replacingOccurrences(of: "_OBJC_PROTOCOL_$_", with: ""))
            default: break
            }
        }
        return out
    }

    // MARK: Functions

    private func buildFunctions() {
        var starts = Set<UInt64>()
        if let fs = functionStarts {
            var addr = textBase
            var p = fs.off
            let end = fs.off + fs.size
            while p < end {
                var delta: UInt64 = 0
                var shift: UInt64 = 0
                while p < end {
                    let b = u8(p)
                    p += 1
                    delta |= UInt64(b & 0x7F) << shift
                    shift += 7
                    if b & 0x80 == 0 || shift > 63 { break }
                }
                if delta == 0 { break }
                addr &+= delta
                starts.insert(addr)
            }
        }
        let code = sections.filter { $0.isCode }
        for (a, _) in names where code.contains(where: { $0.contains(a) }) { starts.insert(a) }
        if let e = entryPoint {
            starts.insert(e)
            if names[e] == nil { names[e] = "start" }
        }

        let sorted = starts.sorted()
        var out: [Function] = []
        out.reserveCapacity(sorted.count)
        for (i, a) in sorted.enumerated() {
            guard let sec = code.first(where: { $0.contains(a) }) else { continue }
            let next = i + 1 < sorted.count ? sorted[i + 1] : sec.addr + sec.size
            out.append(Function(address: a, end: min(next, sec.addr + sec.size), name: names[a]))
        }
        functions = out
    }

    /// The function an address belongs to.
    func function(containing a: UInt64) -> Function? {
        var lo = 0, hi = functions.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let f = functions[mid]
            if a < f.address { hi = mid - 1 } else if a >= f.end { lo = mid + 1 } else { return f }
        }
        return nil
    }

    func displayName(for a: UInt64) -> String {
        if let n = names[a] { return SwiftDemangler.display(n) }
        return String(format: "sub_%llx", a)
    }

    // MARK: Describing addresses (for disassembly comments)

    func describe(address a: UInt64, loaded: Bool) -> String? {
        if !loaded, let n = names[a] { return SwiftDemangler.display(n) }
        guard let sec = section(containing: a) else { return nil }
        switch sec.name {
        case "__cstring", "__objc_methname", "__objc_classname", "__objc_methtype", "__oslogstring", "__swift5_reflstr":
            guard !loaded, let s = cString(atVM: a, max: 200) else { break }
            return Self.quote(s)
        case "__cfstring":
            if let p = pointer(atVM: a + 16).address, let s = cString(atVM: p, max: 200) { return "@" + Self.quote(s) }
        case "__objc_selrefs":
            if let s = selector(atRef: a) { return "@selector(\(s))" }
        case "__objc_classrefs", "__objc_superrefs":
            switch pointer(atVM: a) {
            case .bind(let n?): return SwiftDemangler.display(Self.stripClassPrefix(n))
            case .rebase(let c):
                if let cls = classes.first(where: { $0.address == c }) { return cls.displayName }
            default: break
            }
        case "__got", "__auth_got", "__la_symbol_ptr", "__nl_symbol_ptr", "__auth_ptr":
            if case .bind(let n?) = pointer(atVM: a) { return SwiftDemangler.display(n) }
        default:
            break
        }
        if let n = names[a] { return SwiftDemangler.display(n) }
        return sec.name
    }

    static func quote(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\"", with: "\\\"")
        if t.count > 80 { t = String(t.prefix(80)) + "…" }
        return "\"" + t + "\""
    }
}

/// Decodes the few ARM64 instruction forms needed to follow addresses.
enum ARM64 {
    static func rd(_ w: UInt32) -> UInt32 { w & 31 }

    static func signExtend(_ v: UInt64, bits: Int) -> Int64 {
        let shift = 64 - bits
        return Int64(bitPattern: v << UInt64(shift)) >> Int64(shift)
    }

    /// ADRP: returns the target page.
    static func adrp(_ w: UInt32, pc: UInt64) -> UInt64? {
        guard w & 0x9F00_0000 == 0x9000_0000 else { return nil }
        let immlo = UInt64((w >> 29) & 3)
        let immhi = UInt64((w >> 5) & 0x7FFFF)
        let imm = signExtend((immhi << 2) | immlo, bits: 21) << 12
        return UInt64(bitPattern: Int64(bitPattern: pc & ~0xFFF) &+ imm)
    }

    /// ADR: returns the target address.
    static func adr(_ w: UInt32, pc: UInt64) -> UInt64? {
        guard w & 0x9F00_0000 == 0x1000_0000 else { return nil }
        let immlo = UInt64((w >> 29) & 3)
        let immhi = UInt64((w >> 5) & 0x7FFFF)
        return UInt64(bitPattern: Int64(bitPattern: pc) &+ signExtend((immhi << 2) | immlo, bits: 21))
    }

    /// ADD Xd, Xn, #imm (64-bit): (rd, rn, imm).
    static func addImm(_ w: UInt32) -> (UInt32, UInt32, UInt64)? {
        guard w & 0xFF80_0000 == 0x9100_0000 else { return nil }
        let shift: UInt64 = (w >> 22) & 1 == 1 ? 12 : 0
        return (w & 31, (w >> 5) & 31, UInt64((w >> 10) & 0xFFF) << shift)
    }

    /// LDR Xt, [Xn, #imm]: (rn, byte offset).
    static func ldrX(_ w: UInt32) -> (UInt32, UInt64)? {
        guard w & 0xFFC0_0000 == 0xF940_0000 else { return nil }
        return ((w >> 5) & 31, UInt64((w >> 10) & 0xFFF) * 8)
    }

    /// LDR Wt, [Xn, #imm]: (rn, byte offset).
    static func ldrW(_ w: UInt32) -> (UInt32, UInt64)? {
        guard w & 0xFFC0_0000 == 0xB940_0000 else { return nil }
        return ((w >> 5) & 31, UInt64((w >> 10) & 0xFFF) * 4)
    }

    /// B / BL: (target, isCall).
    static func branch(_ w: UInt32, pc: UInt64) -> (UInt64, Bool)? {
        let op = w & 0xFC00_0000
        guard op == 0x1400_0000 || op == 0x9400_0000 else { return nil }
        let off = signExtend(UInt64(w & 0x03FF_FFFF), bits: 26) << 2
        return (UInt64(bitPattern: Int64(bitPattern: pc) &+ off), op == 0x9400_0000)
    }

    /// B.cond, CBZ/CBNZ (imm19) and TBZ/TBNZ (imm14) targets.
    static func conditionalTarget(_ w: UInt32, pc: UInt64) -> UInt64? {
        if w & 0xFF00_0010 == 0x5400_0000 || w & 0x7E00_0000 == 0x3400_0000 {
            let off = signExtend(UInt64((w >> 5) & 0x7FFFF), bits: 19) << 2
            return UInt64(bitPattern: Int64(bitPattern: pc) &+ off)
        }
        if w & 0x7E00_0000 == 0x3600_0000 {
            let off = signExtend(UInt64((w >> 5) & 0x3FFF), bits: 14) << 2
            return UInt64(bitPattern: Int64(bitPattern: pc) &+ off)
        }
        return nil
    }

    static func isReturn(_ w: UInt32) -> Bool {
        w == 0xD65F_03C0 || w & 0xFFFF_FBFF == 0xD65F_0BFF // ret, retaa/retab
    }
}

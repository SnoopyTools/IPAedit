import Foundation

/// Demangles Swift symbols with the Swift runtime's own `swift_demangle`,
/// looked up at runtime so nothing extra is bundled.
enum SwiftDemangler {
    private typealias DemangleFn = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?,
                                                   UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?

    private static let fn: DemangleFn? = {
        let handles = [dlopen(nil, RTLD_NOW), dlopen("/usr/lib/swift/libswiftCore.dylib", RTLD_NOW)]
        for h in handles {
            if let h = h, let sym = dlsym(h, "swift_demangle") {
                return unsafeBitCast(sym, to: DemangleFn.self)
            }
        }
        return nil
    }()

    static var isAvailable: Bool { fn != nil }

    static func looksMangled(_ s: String) -> Bool {
        s.hasPrefix("$s") || s.hasPrefix("_$s") || s.hasPrefix("$S") || s.hasPrefix("_$S")
            || s.hasPrefix("_T0") || s.hasPrefix("_Tt") || s.hasPrefix("$e") || s.hasPrefix("_$e")
    }

    static func demangle(_ s: String) -> String? {
        guard let fn = fn, looksMangled(s) else { return nil }
        // Symbol-table names carry a leading underscore before the "$s" prefix.
        let input = s.hasPrefix("_$") ? String(s.dropFirst()) : s
        return input.withCString { p -> String? in
            guard let out = fn(p, strlen(p), nil, nil, 0) else { return nil }
            defer { free(out) }
            let r = String(cString: out)
            return r == input ? nil : r
        }
    }

    /// Demangled Swift name, or the name itself (minus the C underscore) otherwise.
    static func display(_ s: String) -> String {
        if let d = demangle(s) { return d }
        if s.hasPrefix("_") && !s.hasPrefix("__") && !s.hasPrefix("_OBJC_") { return String(s.dropFirst()) }
        return s
    }
}

struct Instruction: Identifiable {
    var id: UInt64 { address }
    var address: UInt64
    var word: UInt32
    var mnemonic: String
    var operands: String
    var comment: String?
    /// Branch/call destination, if the instruction has a direct one.
    var target: UInt64?
}

/// ARM64 disassembler backed by Capstone, plus comments that follow ADRP pairs
/// to strings, selectors, classes and imports.
final class Disassembler {
    private let handle: UnsafeMutableRawPointer
    private let lock = NSLock()

    init?() {
        guard let h = ipa_disasm_open() else { return nil }
        handle = h
    }

    deinit { ipa_disasm_close(handle) }

    static var capstoneVersion: String {
        let v = Int(ipa_disasm_version())
        return "\(v / 100).\(v % 100)"
    }

    func disassemble(_ code: Data, at address: UInt64, max: Int) -> [Instruction] {
        guard !code.isEmpty, max > 0 else { return [] }
        lock.lock()
        defer { lock.unlock() }
        var buf = [IPAInsn](repeating: IPAInsn(), count: max)
        let n = code.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return buf.withUnsafeMutableBufferPointer { out in
                Int(ipa_disasm(handle, p, raw.count, address, out.baseAddress, max))
            }
        }
        var result: [Instruction] = []
        result.reserveCapacity(n)
        for i in 0..<n {
            var insn = buf[i]
            let mnemonic = withUnsafePointer(to: &insn.mnemonic) {
                $0.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
            }
            let operands = withUnsafePointer(to: &insn.operands) {
                $0.withMemoryRebound(to: CChar.self, capacity: 160) { String(cString: $0) }
            }
            result.append(Instruction(address: insn.address, word: insn.word, mnemonic: mnemonic, operands: operands))
        }
        return result
    }

    /// Disassembles `count` bytes of code starting at a virtual address.
    func disassemble(image: MachOImage, from start: UInt64, to end: UInt64, max: Int = 4000) -> [Instruction] {
        guard end > start, let off = image.fileOffset(forVM: start) else { return [] }
        let length = Int(min(end - start, UInt64(max * 4)))
        var list = disassemble(image.bytes(fileOffset: off, count: length), at: start, max: max)
        Self.annotate(&list, image: image)
        return list
    }

    static func annotate(_ list: inout [Instruction], image: MachOImage) {
        var regs: [UInt32: UInt64] = [:]
        for i in list.indices {
            let w = list[i].word
            let pc = list[i].address
            if case let (t, isCall)? = ARM64.branch(w, pc: pc) {
                list[i].target = t
                list[i].comment = image.displayName(for: t)
                if isCall { regs.removeAll() }
                continue
            }
            if let t = ARM64.conditionalTarget(w, pc: pc) {
                list[i].target = t
                continue
            }
            if let page = ARM64.adrp(w, pc: pc) {
                regs[ARM64.rd(w)] = page
                continue
            }
            if let a = ARM64.adr(w, pc: pc) {
                regs[ARM64.rd(w)] = a
                list[i].comment = image.describe(address: a, loaded: false)
                continue
            }
            if case let (rd, rn, imm)? = ARM64.addImm(w), let page = regs[rn] {
                let a = page &+ imm
                regs[rd] = a
                list[i].comment = image.describe(address: a, loaded: false)
                continue
            }
            if case let (rn, imm)? = ARM64.ldrX(w) ?? ARM64.ldrW(w), let page = regs[rn] {
                list[i].comment = image.describe(address: page &+ imm, loaded: true)
                regs[ARM64.rd(w)] = nil
                continue
            }
            if ARM64.isReturn(w) { regs.removeAll() }
        }
    }
}

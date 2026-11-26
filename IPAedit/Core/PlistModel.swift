import Foundation

enum PlistType: String, CaseIterable, Identifiable {
    case dictionary = "Dictionary", array = "Array", string = "String", integer = "Number (Int)",
         real = "Number (Real)", boolean = "Boolean", date = "Date", data = "Data"
    var id: String { rawValue }
    var short: String {
        switch self {
        case .dictionary: return "Dict"
        case .array: return "Array"
        case .string: return "String"
        case .integer: return "Int"
        case .real: return "Real"
        case .boolean: return "Bool"
        case .date: return "Date"
        case .data: return "Data"
        }
    }
}

final class PlistNode: ObservableObject, Identifiable {
    let id = UUID()
    @Published var key: String
    @Published var type: PlistType
    @Published var string: String = ""
    @Published var integer: Int = 0
    @Published var real: Double = 0
    @Published var bool: Bool = false
    @Published var date: Date = Date()
    @Published var data: Data = Data()
    @Published var children: [PlistNode] = []
    weak var parent: PlistNode?

    init(key: String, type: PlistType) {
        self.key = key
        self.type = type
    }

    var isContainer: Bool { type == .dictionary || type == .array }

    var summary: String {
        switch type {
        case .dictionary: return "\(children.count) key\(children.count == 1 ? "" : "s")"
        case .array: return "\(children.count) item\(children.count == 1 ? "" : "s")"
        case .string: return string
        case .integer: return String(integer)
        case .real: return String(real)
        case .boolean: return bool ? "YES" : "NO"
        case .date: return date.formatted(date: .abbreviated, time: .standard)
        case .data:
            let prefix = data.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " ")
            return "<\(data.count) bytes> " + prefix + (data.count > 24 ? "…" : "")
        }
    }

    func label(in parent: PlistNode?) -> String {
        if let parent = parent, parent.type == .array,
           let i = parent.children.firstIndex(where: { $0 === self }) {
            return "Item \(i)"
        }
        return key
    }

    // MARK: Conversion

    static func from(_ value: Any, key: String = "Root") -> PlistNode {
        if let dict = value as? [String: Any] {
            let node = PlistNode(key: key, type: .dictionary)
            node.children = dict.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { k in
                let child = from(dict[k]!, key: k)
                child.parent = node
                return child
            }
            return node
        }
        if let array = value as? [Any] {
            let node = PlistNode(key: key, type: .array)
            node.children = array.map { v in
                let child = from(v, key: "")
                child.parent = node
                return child
            }
            return node
        }
        if let s = value as? String {
            let n = PlistNode(key: key, type: .string); n.string = s; return n
        }
        if let d = value as? Data {
            let n = PlistNode(key: key, type: .data); n.data = d; return n
        }
        if let d = value as? Date {
            let n = PlistNode(key: key, type: .date); n.date = d; return n
        }
        if let num = value as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                let n = PlistNode(key: key, type: .boolean); n.bool = num.boolValue; return n
            }
            if CFNumberIsFloatType(num as CFNumber) {
                let n = PlistNode(key: key, type: .real); n.real = num.doubleValue; return n
            }
            let n = PlistNode(key: key, type: .integer); n.integer = num.intValue; return n
        }
        let n = PlistNode(key: key, type: .string)
        n.string = String(describing: value)
        return n
    }

    func toValue() -> Any {
        switch type {
        case .dictionary:
            let d = NSMutableDictionary()
            for c in children { d[c.key] = c.toValue() }
            return d
        case .array:
            return NSMutableArray(array: children.map { $0.toValue() })
        case .string: return string as NSString
        case .integer: return NSNumber(value: integer)
        case .real: return NSNumber(value: real)
        case .boolean: return NSNumber(value: bool)
        case .date: return date as NSDate
        case .data: return data as NSData
        }
    }

    /// Changes the node's type, converting the value where it makes sense.
    func convert(to newType: PlistType) {
        guard newType != type else { return }
        let text = isContainer ? "" : summary
        switch newType {
        case .string: string = type == .data ? data.hexString : text
        case .integer: integer = Int(text) ?? (bool ? 1 : Int(real))
        case .real: real = Double(text) ?? Double(integer)
        case .boolean: bool = ["yes", "true", "1"].contains(text.lowercased())
        case .data: data = Data(string.utf8)
        case .date: date = Date()
        case .dictionary, .array:
            if !(type == .dictionary || type == .array) { children = [] }
        }
        if newType == .dictionary, type == .array {
            for (i, c) in children.enumerated() where c.key.isEmpty { c.key = "Item \(i)" }
        }
        type = newType
    }

    func uniqueChildKey(_ base: String) -> String {
        var candidate = base
        var n = 2
        while children.contains(where: { $0.key == candidate }) {
            candidate = "\(base) \(n)"
            n += 1
        }
        return candidate
    }
}

/// A plist file loaded for editing.
final class PlistDocument: ObservableObject {
    let url: URL
    @Published var root: PlistNode
    @Published var format: PropertyListSerialization.PropertyListFormat
    @Published var dirty = false

    init(url: URL) throws {
        self.url = url
        let data = try Data(contentsOf: url)
        var fmt = PropertyListSerialization.PropertyListFormat.xml
        let value = try PropertyListSerialization.propertyList(from: data, options: [], format: &fmt)
        root = PlistNode.from(value)
        format = fmt == .openStep ? .xml : fmt
    }

    func serialized(format: PropertyListSerialization.PropertyListFormat? = nil) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: root.toValue(), format: format ?? self.format, options: 0)
    }

    func xmlString() -> String {
        (try? serialized(format: .xml)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func replace(withXML xml: String) throws {
        let value = try PropertyListSerialization.propertyList(from: Data(xml.utf8), options: [], format: nil)
        root = PlistNode.from(value)
        dirty = true
    }

    func save() throws {
        try serialized().write(to: url)
        dirty = false
    }

    func touch() {
        dirty = true
        objectWillChange.send()
    }
}

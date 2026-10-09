// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The hex view (PLAN.md §11.2, §11.4: the fallback view for any binary file).
public enum HexDump {
    /// `00000010  48 65 6c 6c 6f 20 77 6f  72 6c 64 0a 00 01 02 03  |Hello world.....|`
    public static func lines(_ data: Data, from start: Int = 0, count: Int = 256) -> [String] {
        let bytes = [UInt8](data)
        var out: [String] = []
        var offset = max(0, start) / 16 * 16
        while offset < bytes.count, out.count < count {
            let row = bytes[offset..<min(offset + 16, bytes.count)]
            var hex = ""
            for (i, b) in row.enumerated() {
                hex += String(format: "%02x ", b)
                if i == 7 { hex += " " }
            }
            hex = hex.padding(toLength: 49, withPad: " ", startingAt: 0)
            let ascii = String(row.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "." })
            out.append(String(format: "%08x  ", offset) + hex + " |\(ascii)|")
            offset += 16
        }
        return out
    }
}

/// The WASM inspector (PLAN.md §11.2): sections and their sizes, imports, exports, functions and
/// memory, read from the binary.
public struct WasmInfo: Sendable, Equatable {
    public struct Section: Sendable, Equatable, Identifiable {
        public var id: Int { offset }
        public let name: String
        public let size: Int
        public let offset: Int
    }
    public struct Entry: Sendable, Equatable, Hashable {
        public let module: String
        public let name: String
        public let kind: String
    }

    public var sections: [Section] = []
    public var imports: [Entry] = []
    public var exports: [Entry] = []
    public var functions = 0
    public var memory: (min: Int, max: Int?)? = nil
    public var dataSegments = 0

    public static func == (a: Self, b: Self) -> Bool {
        a.sections == b.sections && a.imports == b.imports && a.exports == b.exports && a.functions == b.functions
            && a.memory?.min == b.memory?.min && a.memory?.max == b.memory?.max && a.dataSegments == b.dataSegments
    }

    static let names = [0: "custom", 1: "type", 2: "import", 3: "function", 4: "table", 5: "memory", 6: "global", 7: "export",
                        8: "start", 9: "element", 10: "code", 11: "data", 12: "data count", 13: "tag"]
    static let kinds = [0: "function", 1: "table", 2: "memory", 3: "global", 4: "tag"]

    public struct Failure: Error, Equatable { public let message: String }

    public init(_ data: Data) throws {
        let b = [UInt8](data)
        guard b.count >= 8, b[0] == 0, b[1] == 0x61, b[2] == 0x73, b[3] == 0x6d else { throw Failure(message: "Not a WebAssembly module") }
        var p = 8
        func u32() throws -> Int {
            var result = 0, shift = 0
            while true {
                guard p < b.count else { throw Failure(message: "Truncated") }
                let byte = b[p]; p += 1
                result |= Int(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
                guard shift < 35 else { throw Failure(message: "Bad number") }
            }
        }
        func name() throws -> String {
            let n = try u32()
            guard p + n <= b.count else { throw Failure(message: "Truncated") }
            defer { p += n }
            return String(decoding: b[p..<(p + n)], as: UTF8.self)
        }
        func limits() throws -> (Int, Int?) {
            let flags = try u32(); let min = try u32()
            return (min, flags & 1 == 1 ? try u32() : nil)
        }
        while p < b.count {
            let id = Int(b[p]); p += 1
            let size = try u32()
            let start = p, end = p + size
            guard end <= b.count else { throw Failure(message: "Truncated section") }
            var label = Self.names[id] ?? "unknown \(id)"
            switch id {
            case 0: label = "custom: " + (try name())
            case 2:
                for _ in 0..<(try u32()) {
                    let module = try name(), field = try name()
                    let kind = Int(b[p]); p += 1
                    switch kind {
                    case 0: _ = try u32()
                    case 1: p += 1; _ = try limits()
                    case 2: memory = try limits()
                    case 3: p += 2
                    default: _ = try u32()
                    }
                    imports.append(Entry(module: module, name: field, kind: Self.kinds[kind] ?? "?"))
                }
            case 3: functions += try u32()
            case 5: if try u32() > 0 { memory = try limits() }
            case 7:
                for _ in 0..<(try u32()) {
                    let field = try name()
                    let kind = Int(b[p]); p += 1
                    _ = try u32()
                    exports.append(Entry(module: "", name: field, kind: Self.kinds[kind] ?? "?"))
                }
            case 11: dataSegments = try u32()
            default: break
            }
            sections.append(Section(name: label, size: size, offset: start))
            p = end
        }
    }
}

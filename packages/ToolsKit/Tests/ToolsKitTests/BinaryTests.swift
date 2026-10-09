// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import ToolsKit

struct BinaryTests {
    @Test func hexDump() {
        let lines = HexDump.lines(Data("Hello world\n".utf8 + [0, 1, 2, 3, 0xff]))
        #expect(lines == [
            "00000000  48 65 6c 6c 6f 20 77 6f  72 6c 64 0a 00 01 02 03  |Hello world.....|",
            "00000010  ff                                                |.|",
        ])
    }

    @Test func readsAWasmModule() throws {
        // (module (import "wasi_snapshot_preview1" "fd_write" (func)) (memory 1 2)
        //         (func $add) (export "add" (func 1)) (export "memory" (memory 0)) + a custom "name" section)
        let module: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
            0x01, 0x04, 0x01, 0x60, 0x00, 0x00,                                         // type: () -> ()
            0x02, 0x23, 0x01, 0x16] + Array("wasi_snapshot_preview1".utf8) + [0x08] + Array("fd_write".utf8) + [0x00, 0x00,
            0x03, 0x02, 0x01, 0x00,                                                     // one function
            0x05, 0x04, 0x01, 0x01, 0x01, 0x02,                                         // memory 1..2
            0x07, 0x10, 0x02, 0x03] + Array("add".utf8) + [0x00, 0x01, 0x06] + Array("memory".utf8) + [0x02, 0x00,
            0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b,                                         // code: empty body
            0x00, 0x05, 0x04] + Array("name".utf8)
        let info = try WasmInfo(Data(module))
        #expect(info.sections.map(\.name) == ["type", "import", "function", "memory", "export", "code", "custom: name"])
        #expect(info.imports == [.init(module: "wasi_snapshot_preview1", name: "fd_write", kind: "function")])
        #expect(info.exports.map(\.name) == ["add", "memory"] && info.exports.map(\.kind) == ["function", "memory"])
        #expect(info.functions == 1 && info.memory?.min == 1 && info.memory?.max == 2)
        #expect(throws: WasmInfo.Failure(message: "Not a WebAssembly module")) { try WasmInfo(Data("hello".utf8)) }
    }
}

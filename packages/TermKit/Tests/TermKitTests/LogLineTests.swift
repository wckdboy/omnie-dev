// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Testing
@testable import TermKit

struct LogLineTests {
    let files: Set<String> = ["src/main.ts", "app/greeting.py", "tests/a.test.ts"]
    func find(_ text: String) -> LogLine.Location? { LogLine.location(in: text) { files.contains($0) } }

    @Test func findsSourceLocations() {
        #expect(find("src/main.ts:4:7 error TS2322: Type 'number' is not assignable") == .init(path: "src/main.ts", line: 4, column: 7))
        #expect(find("    at render (omnie-run://local/src/main.ts:12:3)") == .init(path: "src/main.ts", line: 12, column: 3))
        #expect(find("  File \"/project/app/greeting.py\", line 3, in greet") == .init(path: "app/greeting.py", line: 3, column: nil))
        #expect(find("✗ tests/a.test.ts › adds") == nil)                 // no line number
        #expect(find("see node_modules/x/index.js:1:1") == nil)          // not a project file
        #expect(find("Uncaught Error: boom (/src/main.ts:9)") == .init(path: "src/main.ts", line: 9, column: nil))
    }

    @Test func errorsAndJSON() {
        #expect(LogLine.isError("! careful") && LogLine.isError("✗ math › adds") && LogLine.isError("    at f (src/a.ts:1:2)"))
        #expect(!LogLine.isError("3 passed (12 ms)") && !LogLine.isError("hello"))
        #expect(LogLine.prettyJSON(#"{"level":"info","msg":"ready","port":5173}"#) == "{\n  \"level\" : \"info\",\n  \"msg\" : \"ready\",\n  \"port\" : 5173\n}")
        #expect(LogLine.prettyJSON("{not json}") == nil && LogLine.prettyJSON("plain") == nil)
    }
}

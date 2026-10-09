// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import ToolsKit

struct CronTests {
    var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    @Test func describes() throws {
        #expect(try Cron("30 9 * * 1-5").description == "At 09:30, on Monday through Friday")
        #expect(try Cron("*/15 * * * *").description == "At minutes 0, 15, 30 and 45 of every hour")
        #expect(try Cron("0 * * * *").description == "At minute 0 past every hour")
        #expect(try Cron("@daily").description == "At 00:00")
        #expect(try Cron("0 0 1 jan *").description == "At 00:00, on day 1 of the month, in January")
        #expect(try Cron("*/10 9-17 * * mon,wed").description == "Every 10 minutes during 09:00–17:59, on Monday and Wednesday")
        #expect(try Cron("* * * * *").description == "Every minute")
        #expect(throws: Cron.Failure.fieldCount(4)) { try Cron("* * * *") }
        #expect(throws: Cron.Failure.bad(field: "hour", value: "25")) { try Cron("0 25 * * *") }
    }

    @Test func nextRuns() throws {
        let start = date("2026-10-09T12:00:00Z")   // a Friday
        let weekdays = try Cron("30 9 * * 1-5").next(3, after: start, calendar: utc)
        #expect(weekdays.map { ISO8601DateFormatter().string(from: $0) } == ["2026-10-12T09:30:00Z", "2026-10-13T09:30:00Z", "2026-10-14T09:30:00Z"])
        // Day of month OR day of week when both are set (cron's rule): the 13th or any Friday.
        let either = try Cron("0 0 13 * 5").next(3, after: start, calendar: utc)
        #expect(either.map { ISO8601DateFormatter().string(from: $0) } == ["2026-10-13T00:00:00Z", "2026-10-16T00:00:00Z", "2026-10-23T00:00:00Z"])
        #expect(try Cron("0 0 29 2 *").next(1, after: start, calendar: utc).first.map { ISO8601DateFormatter().string(from: $0) } == "2028-02-29T00:00:00Z")
    }
}

struct RegexExplainerTests {
    @Test func explainsPieces() {
        let parts = RegexExplainer.explain(#"^(\w+)@([a-z0-9.-]+)\.com$"#)
        #expect(parts.map(\.token) == ["^", "(", "\\w+", ")", "@", "(", "[a-z0-9.-]+", ")", "\\.", "com", "$"])
        #expect(parts[2].meaning == "a word character (letter, digit or _), one or more times" && parts[2].depth == 1)
        #expect(parts[6].meaning == "one of a–z, 0–9, \".\", \"-\", one or more times")
        #expect(parts[9].meaning == "the text \"com\"")
        let more = RegexExplainer.explain(#"(?<year>\d{4})-(?:\d{2})?colou?r"#)
        #expect(more[0].meaning == "start of group 1, named \"year\"")
        #expect(more[1].meaning == "a digit, exactly 4 times")
        #expect(more[4].meaning == "start of a group (not captured)" && more[5].meaning == "a digit, exactly 2 times")
        #expect(more[6].token == ")?" && more[6].meaning == "end of the group, optionally")
        #expect(more.map(\.token).suffix(3) == ["colo", "u?", "r"])
    }
}

struct YAMLLabTests {
    @Test func yamlToJSONAndBack() {
        let report = Patterns.yaml("name: demo\ntags: [a, b]\nn: 3\n")
        #expect(report.json == "{\n  \"n\" : 3,\n  \"name\" : \"demo\",\n  \"tags\" : [\n    \"a\",\n    \"b\"\n  ]\n}")
        #expect(Patterns.yaml("  ").error == "Empty")
        let yaml = Patterns.yamlFromJSON(#"{"name": "demo", "on": true, "list": [1, {"a": "x y", "b": "yes"}], "empty": {}, "url": "https://x"}"#)
        #expect(yaml == "empty: {}\nlist:\n- 1\n- a: x y\n  b: \"yes\"\nname: demo\n\"on\": true\nurl: \"https://x\"\n")
        // "on" is quoted: YAML 1.1 reads a bare on as true. And it reads back the same.
        let back = YAML.parse(yaml!) as? [String: Any]
        #expect(back?["name"] as? String == "demo" && (back?["list"] as? [Any])?.count == 2)
    }
}

// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Keeps "make the tests pass" honest: small models often edit the test until it agrees with the
/// bug (seen on the iPad: Qwen 7B rewrote orbit.test.ts five times). When the goal is passing
/// tests and doesn't ask for test changes, writes to test files are refused with a pointer to the
/// code under test.
public enum TestGuard {
    /// Test files in the languages the app runs: JS/TS, Python, Swift.
    public static func isTestPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        let name = (lower as NSString).lastPathComponent
        if lower.hasPrefix("tests/") || lower.hasPrefix("test/") || lower.contains("/tests/") || lower.contains("/test/")
            || lower.contains("__tests__/") || lower.hasPrefix("spec/") || lower.contains("/spec/") { return true }
        if name.contains(".test.") || name.contains(".spec.") { return true }
        if name.hasPrefix("test_") && name.hasSuffix(".py") || name.hasSuffix("_test.py") { return true }
        if name.hasSuffix("tests.swift") || name.hasSuffix("test.swift") { return true }
        return false
    }

    /// The goal is to get tests passing, and it doesn't ask to add or change tests.
    public static func wantsPassingTests(_ goal: String) -> Bool {
        let g = goal.lowercased()
        let aboutTests = g.contains("test") && (g.contains("pass") || g.contains("failing") || g.contains("fail") || g.contains("green"))
        let changesTests = ["add a test", "add tests", "write a test", "write tests", "new test", "update the test", "change the test",
                            "edit the test", "fix the test file", "tests for", "test for", "the test is wrong", "the tests are wrong"]
            .contains { g.contains($0) }
        return aboutTests && !changesTests
    }

    /// The refusal for writing `path` under `goal`, or nil when it's fine.
    public static func refusal(goal: String, path: String) -> String? {
        guard wantsPassingTests(goal), isTestPath(path) else { return nil }
        let name = (path as NSString).lastPathComponent
        let subject = name.replacingOccurrences(of: ".test.", with: ".").replacingOccurrences(of: ".spec.", with: ".")
            .replacingOccurrences(of: "test_", with: "").replacingOccurrences(of: "_test.py", with: ".py")
            .replacingOccurrences(of: "Tests.swift", with: ".swift")
        return "Not changed: \(path) is a test, and the task is to make the tests pass. Tests describe the right behavior; "
            + "change the code they test instead (for \(name), most likely \(subject)). Read it, fix the bug there, then run_tests."
    }
}

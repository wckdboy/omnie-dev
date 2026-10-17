// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The on-device debugger (PLAN.md §5.3): runs a project's JavaScript/TypeScript with a hook at the
/// start of every statement, and stops at a breakpoint or while stepping. Stopping is synchronous —
/// the sandbox worker parks on a request the app holds open (the scheme handler's `debug/pause`
/// route) and reads the chosen action back from its response, so the JavaScript stack, and its
/// locals, are still live when the pause is shown.
///
/// The project's own modules are loaded through RunKit's small JavaScript loader and instrumented;
/// npm packages aren't loaded yet, so a module that imports one says so.
public enum Debugger {
    /// Where the program stopped, and what's in scope there.
    public struct Pause: Sendable, Equatable {
        public struct Frame: Sendable, Equatable {
            public var file: String
            public var line: Int
            public var column: Int
            public var name: String

            public init(file: String, line: Int, column: Int, name: String) {
                self.file = file; self.line = line; self.column = column; self.name = name
            }
        }

        public struct Variable: Sendable, Equatable {
            public var name: String
            public var value: String
            public init(name: String, value: String) { self.name = name; self.value = value }
        }

        public enum Reason: String, Sendable { case breakpoint, step }

        /// The file the stop is in (a project-relative path), and the line (1-based).
        public var file: String
        public var line: Int
        public var reason: Reason
        /// Innermost first; the first frame is where the stop is.
        public var stack: [Frame]
        public var locals: [Variable]

        public init(file: String, line: Int, reason: Reason, stack: [Frame], locals: [Variable]) {
            self.file = file; self.line = line; self.reason = reason; self.stack = stack; self.locals = locals
        }
    }

    /// What to do when the program stops.
    public enum Action: String, Sendable, CaseIterable {
        case resume = "continue"
        case stepOver, stepInto, stepOut, stop

        public var title: String {
            switch self {
            case .resume: "Continue"
            case .stepOver: "Step over"
            case .stepInto: "Step into"
            case .stepOut: "Step out"
            case .stop: "Stop"
            }
        }
    }

    /// A breakpoint: a project-relative file and a 1-based line.
    public struct Breakpoint: Sendable, Hashable {
        public var file: String
        public var line: Int
        public init(file: String, line: Int) { self.file = file; self.line = line }
    }

    /// The JSON the debug worker is started with: the entry path and the breakpoints.
    static func spec(entry: String, breakpoints: Set<Breakpoint>) -> String {
        let list = breakpoints.sorted { ($0.file, $0.line) < ($1.file, $1.line) }
            .map { #"{"file":\#(quoted($0.file)),"line":\#($0.line)}"# }.joined(separator: ",")
        return #"{"entry":\#(quoted(entry)),"breakpoints":[\#(list)]}"#
    }

    /// The pause the worker sent, decoded from the held request's body.
    struct Payload: Decodable {
        struct Frame: Decodable { var file: String; var line: Int; var column: Int; var name: String? }
        struct Variable: Decodable { var name: String; var value: String }
        var file: String
        var line: Int
        var reason: String
        var stack: [Frame]
        var locals: [Variable]

        var pause: Pause {
            Pause(file: file, line: line, reason: Pause.Reason(rawValue: reason) ?? .breakpoint,
                  stack: stack.map { Pause.Frame(file: $0.file, line: $0.line, column: $0.column, name: $0.name ?? "") },
                  locals: locals.map { Pause.Variable(name: $0.name, value: $0.value) })
        }
    }

    private static func quoted(_ text: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [text])
        return data.map { String(decoding: $0.dropFirst().dropLast(), as: UTF8.self) } ?? "\"\""
    }
}

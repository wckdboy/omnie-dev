// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The cron explainer in the Patterns lab (PLAN.md §11.1, §11.4): a deterministic parser, not a
/// model. Standard five fields (minute hour day-of-month month day-of-week), lists, ranges,
/// steps, month and day names, and the @ macros.
public struct Cron: Sendable, Equatable {
    public let minutes: Set<Int>, hours: Set<Int>, days: Set<Int>, months: Set<Int>, weekdays: Set<Int>
    /// Whether day-of-month / day-of-week were restricted (cron ORs them when both are).
    let dayRestricted: Bool, weekdayRestricted: Bool
    let fields: [String]

    public enum Failure: Error, Equatable, LocalizedError {
        case fieldCount(Int)
        case bad(field: String, value: String)
        public var errorDescription: String? {
            switch self {
            case .fieldCount(let n): "Cron needs 5 fields (minute hour day month weekday), not \(n)."
            case .bad(let field, let value): "\"\(value)\" isn't a valid \(field)."
            }
        }
    }

    static let macros = ["@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *", "@monthly": "0 0 1 * *",
                         "@weekly": "0 0 * * 0", "@daily": "0 0 * * *", "@midnight": "0 0 * * *", "@hourly": "0 * * * *"]
    static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    static let dayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
    static let monthWords = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    static let dayWords = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    public init(_ expression: String) throws {
        let text = Self.macros[expression.trimmingCharacters(in: .whitespaces).lowercased()] ?? expression
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 5 else { throw Failure.fieldCount(parts.count) }
        fields = parts
        minutes = try Self.field(parts[0], "minute", 0...59)
        hours = try Self.field(parts[1], "hour", 0...23)
        days = try Self.field(parts[2], "day of the month", 1...31)
        months = try Self.field(parts[3], "month", 1...12, names: Self.monthNames, nameBase: 1)
        var weekdays = try Self.field(parts[4], "day of the week", 0...7, names: Self.dayNames, nameBase: 0)
        if weekdays.contains(7) { weekdays.remove(7); weekdays.insert(0) }
        self.weekdays = weekdays
        dayRestricted = parts[2] != "*" && parts[2] != "?"
        weekdayRestricted = parts[4] != "*" && parts[4] != "?"
    }

    static func field(_ text: String, _ name: String, _ range: ClosedRange<Int>, names: [String] = [], nameBase: Int = 0) throws -> Set<Int> {
        func value(_ s: String) throws -> Int {
            if let i = names.firstIndex(of: s.lowercased()) { return i + nameBase }
            guard let n = Int(s), range.contains(n) else { throw Failure.bad(field: name, value: s) }
            return n
        }
        var out = Set<Int>()
        for item in text.split(separator: ",").map(String.init) {
            let pieces = item.split(separator: "/", maxSplits: 1).map(String.init)
            var step = 1
            if pieces.count == 2 {
                guard let s = Int(pieces[1]), s > 0 else { throw Failure.bad(field: name, value: item) }
                step = s
            }
            let lower: Int, upper: Int
            if pieces[0] == "*" || pieces[0] == "?" {
                (lower, upper) = (range.lowerBound, range.upperBound == 7 ? 6 : range.upperBound)
            } else if let dash = pieces[0].firstIndex(of: "-") {
                lower = try value(String(pieces[0][..<dash])); upper = try value(String(pieces[0][pieces[0].index(after: dash)...]))
                guard lower <= upper else { throw Failure.bad(field: name, value: item) }
            } else {
                lower = try value(pieces[0]); upper = pieces.count == 2 ? (range.upperBound == 7 ? 6 : range.upperBound) : lower
            }
            out.formUnion(Swift.stride(from: lower, through: upper, by: step))
        }
        return out
    }

    /// Whether the schedule fires at this minute.
    public func matches(_ date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
        guard minutes.contains(c.minute!), hours.contains(c.hour!), months.contains(c.month!) else { return false }
        let dayOK = days.contains(c.day!), weekdayOK = weekdays.contains(c.weekday! - 1)
        // Cron's rule: if both day fields are restricted, either may match.
        if dayRestricted && weekdayRestricted { return dayOK || weekdayOK }
        return dayOK && weekdayOK
    }

    /// The next `count` times it fires after `date` (searching up to five years ahead).
    public func next(_ count: Int, after date: Date, calendar: Calendar = .current) -> [Date] {
        var out: [Date] = []
        guard var t = calendar.date(bySetting: .second, value: 0, of: date) else { return [] }
        t = calendar.date(byAdding: .minute, value: 1, to: t)!
        let limit = calendar.date(byAdding: .year, value: 5, to: date)!
        while out.count < count, t < limit {
            let c = calendar.dateComponents([.month, .hour], from: t)
            // Skip whole days and hours that can't match, so this stays fast.
            if !months.contains(c.month!) {
                t = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: t))!; continue
            }
            if !hours.contains(c.hour!) {
                // To the top of the next hour.
                t = calendar.date(byAdding: .minute, value: 60 - calendar.component(.minute, from: t), to: t)!
                continue
            }
            if matches(t, calendar: calendar) { out.append(t) }
            t = calendar.date(byAdding: .minute, value: 1, to: t)!
        }
        return out
    }

    /// In plain English: "At 09:30, Monday through Friday".
    public var description: String {
        var parts: [String] = []
        let allMinutes = minutes.count == 60, allHours = hours.count == 24
        if allMinutes && allHours { parts.append("Every minute") }
        else if allHours, minutes.count == 1 { parts.append("At minute \(minutes.first!) past every hour") }
        else if allHours { parts.append("At minutes \(Self.list(minutes.sorted().map(String.init))) of every hour") }
        else if minutes.count == 1, hours.count <= 6 {
            parts.append("At " + Self.list(hours.sorted().map { String(format: "%02d:%02d", $0, minutes.first!) }))
        } else if let step = Self.step(fields[0]), hours.count < 24 {
            parts.append("Every \(step) minutes during \(Self.hourRange(hours))")
        } else {
            parts.append("At minutes \(Self.list(minutes.sorted().map(String.init))) past \(Self.hourRange(hours))")
        }
        if dayRestricted { parts.append("on day \(Self.list(days.sorted().map(String.init))) of the month") }
        if weekdayRestricted {
            let sorted = weekdays.sorted()
            let names = Self.isRun(sorted) && sorted.count > 2 ? "\(Self.dayWords[sorted.first!]) through \(Self.dayWords[sorted.last!])"
                : Self.list(sorted.map { Self.dayWords[$0] })
            parts.append((dayRestricted ? "or on " : "on ") + names)
        }
        if months.count < 12 { parts.append("in " + Self.list(months.sorted().map { Self.monthWords[$0 - 1] })) }
        return parts.joined(separator: ", ")
    }

    static func step(_ field: String) -> Int? { field.split(separator: "/").count == 2 ? Int(field.split(separator: "/")[1]) : nil }
    static func isRun(_ xs: [Int]) -> Bool { zip(xs, xs.dropFirst()).allSatisfy { $1 == $0 + 1 } }
    static func hourRange(_ hours: Set<Int>) -> String {
        let h = hours.sorted()
        if isRun(h), h.count > 1 { return String(format: "%02d:00–%02d:59", h.first!, h.last!) }
        return "hours " + list(h.map(String.init))
    }
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }
}

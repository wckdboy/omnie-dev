import Foundation
import Observation

public enum CommandRegistryError: Error, Equatable {
    case duplicateID(CommandID)
    case duplicateShortcut(Shortcut, existing: CommandID)
}

/// The single source of commands. No orphan actions: if the UI can do it, it is registered here.
@MainActor
@Observable
public final class CommandRegistry {
    public private(set) var commands: [Command] = []
    /// IDs in most-recently-run order, newest first. Used to rank palette results.
    public private(set) var recent: [CommandID] = []

    public init() {}

    public func register(_ command: Command) throws {
        if commands.contains(where: { $0.id == command.id }) {
            throw CommandRegistryError.duplicateID(command.id)
        }
        if let shortcut = command.shortcut,
           let clash = commands.first(where: { $0.shortcut == shortcut && !$0.surfaces.isDisjoint(with: command.surfaces) }) {
            throw CommandRegistryError.duplicateShortcut(shortcut, existing: clash.id)
        }
        commands.append(command)
    }

    public func command(_ id: CommandID) -> Command? {
        commands.first { $0.id == id }
    }

    public func commands(for surface: Surfaces) -> [Command] {
        commands.filter { !$0.surfaces.isDisjoint(with: surface) }
    }

    /// Runs a command. Policy approval for `.ask` tiers is the caller's job (PolicyKit, later);
    /// this only records the run.
    public func run(_ id: CommandID) {
        guard let command = command(id) else { return }
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > 20 { recent.removeLast() }
        command.perform()
    }

    /// Palette search. Empty query lists recent commands first, then the rest alphabetically.
    public func search(_ query: String, surface: Surfaces) -> [Command] {
        let pool = commands(for: surface)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let recency = Dictionary(uniqueKeysWithValues: recent.enumerated().map { ($1, $0) })

        if q.isEmpty {
            return pool.sorted {
                let (ra, rb) = (recency[$0.id] ?? .max, recency[$1.id] ?? .max)
                return ra != rb ? ra < rb : $0.title < $1.title
            }
        }

        return pool
            .compactMap { cmd -> (Command, Int)? in
                let fields = [cmd.title] + cmd.keywords + [cmd.menu]
                guard let best = fields.compactMap({ FuzzyMatch.score(q, in: $0) }).max() else { return nil }
                let bonus = recency[cmd.id].map { 20 - $0 } ?? 0
                return (cmd, best + bonus)
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.title < $1.0.title }
            .map(\.0)
    }
}

/// Subsequence matching with bonuses for word starts and contiguous runs.
public enum FuzzyMatch {
    /// Returns nil if `query` is not a subsequence of `text`. Higher is better.
    public static func score(_ query: String, in text: String) -> Int? {
        let q = Array(query.lowercased())
        let t = Array(text.lowercased())
        guard !q.isEmpty else { return 0 }

        var score = 0
        var qi = 0
        var previousMatch = -2
        for (ti, ch) in t.enumerated() where qi < q.count {
            guard ch == q[qi] else { continue }
            score += 1
            if ti == 0 || t[ti - 1] == " " || t[ti - 1] == "-" || t[ti - 1] == "." { score += 8 }
            if ti == previousMatch + 1 { score += 5 }
            previousMatch = ti
            qi += 1
        }
        guard qi == q.count else { return nil }
        if t.starts(with: q) { score += 15 }
        return score - t.count / 8
    }
}

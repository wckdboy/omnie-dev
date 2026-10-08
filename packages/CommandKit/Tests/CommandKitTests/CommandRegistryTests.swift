// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Testing
@testable import CommandKit

@MainActor
struct CommandRegistryTests {
    func makeRegistry() throws -> CommandRegistry {
        let r = CommandRegistry()
        try r.register(Command(id: "palette.open", title: "Open command palette", menu: "View",
                               shortcut: Shortcut("k"), perform: {}))
        try r.register(Command(id: "view.focus", title: "Toggle focus mode", menu: "View",
                               shortcut: Shortcut("f", [.command, .shift]), surfaces: .ide, perform: {}))
        try r.register(Command(id: "git.sync", title: "Sync", menu: "Git",
                               shortcut: Shortcut("s", [.command, .shift]), tier: .askBiometric,
                               keywords: ["push", "pull", "fetch"], perform: {}))
        try r.register(Command(id: "agent.ask", title: "Ask agent", menu: "Agent",
                               shortcut: Shortcut("i"), perform: {}))
        return r
    }

    @Test func rejectsDuplicateIDs() throws {
        let r = try makeRegistry()
        #expect(throws: CommandRegistryError.duplicateID("git.sync")) {
            try r.register(Command(id: "git.sync", title: "Again", menu: "Git", perform: {}))
        }
    }

    @Test func rejectsShortcutClashOnSameSurface() throws {
        let r = try makeRegistry()
        #expect(throws: CommandRegistryError.duplicateShortcut(Shortcut("k"), existing: "palette.open")) {
            try r.register(Command(id: "other", title: "Other", menu: "View", shortcut: Shortcut("k"), perform: {}))
        }
    }

    @Test func allowsSameShortcutOnDisjointSurfaces() throws {
        let r = try makeRegistry()
        // ⌘⇧F is IDE-only, so the vibe surface may reuse it.
        try r.register(Command(id: "vibe.files", title: "Show files", menu: "View",
                               shortcut: Shortcut("f", [.command, .shift]), surfaces: .vibe, perform: {}))
        #expect(r.commands(for: .vibe).contains { $0.id == "vibe.files" })
    }

    @Test func surfacesFilter() throws {
        let r = try makeRegistry()
        #expect(r.commands(for: .ide).count == 4)
        #expect(!r.commands(for: .vibe).contains { $0.id == "view.focus" })
    }

    @Test func searchMatchesKeywordsAndRanksWordStarts() throws {
        let r = try makeRegistry()
        #expect(r.search("push", surface: .all).first?.id == "git.sync")
        #expect(r.search("tfm", surface: .ide).first?.id == "view.focus")
        #expect(r.search("zzz", surface: .all).isEmpty)
    }

    @Test func runRecordsRecencyAndRanksEmptyQuery() throws {
        let r = try makeRegistry()
        var ran = false
        try r.register(Command(id: "test.flag", title: "Zeta", menu: "Test", perform: { ran = true }))
        r.run("test.flag")
        #expect(ran)
        #expect(r.search("", surface: .all).first?.id == "test.flag")
    }

    @Test func shortcutGlyphs() {
        #expect(Shortcut("s", [.command, .shift]).description == "⇧⌘S")
        #expect(Shortcut("\r", [.command]).description == "⌘↩")
    }
}

// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Testing
@testable import GitKit

struct ConflictBlockTests {
    let merged = """
        import a
        <<<<<<< HEAD
        let x = 1
        =======
        let x = 2
        >>>>>>> theirs
        middle
        <<<<<<< HEAD
        mine()
        =======
        >>>>>>> theirs
        end
        """

    @Test func findsBlocksWithContext() {
        let blocks = ConflictFile.blocks(merged, context: 1)
        #expect(blocks.count == 2)
        #expect(blocks[0] == ConflictBlock(ours: ["let x = 1"], theirs: ["let x = 2"], before: ["import a"], after: ["middle"]))
        #expect(blocks[1] == ConflictBlock(ours: ["mine()"], theirs: [], before: ["middle"], after: ["end"]))
    }

    @Test func replacesBlocksAndKeepsUnresolvedOnes() {
        let one = ConflictFile.replacingBlocks(merged, with: ["let x = 3", nil])
        #expect(one.hasPrefix("import a\nlet x = 3\nmiddle\n<<<<<<< HEAD"))
        #expect(ConflictFile.hasMarkers(one))
        let both = ConflictFile.replacingBlocks(merged, with: ["let x = 3", ""])
        #expect(both == "import a\nlet x = 3\nmiddle\nend")
    }
}

struct TextDiffTests {
    @Test func comparesTwoTexts() {
        let diff = FileDiff.texts("a\nb\nc\nd\n", "a\nB\nc\nd\ne\n", oldName: "one.txt", newName: "two.txt")
        #expect(diff.additions == 2 && diff.deletions == 1)
        #expect(diff.hunks.count == 1)
        #expect(diff.hunks[0].removed == ["b"] && diff.hunks[0].added == ["B", "e"])
        #expect(FileDiff.texts("same\n", "same\n").hunks.isEmpty)
        // Far-apart changes are separate hunks with less context.
        let lines = (1...40).map { "line \($0)" }
        var changed = lines; changed[2] = "x"; changed[35] = "y"
        #expect(FileDiff.texts(lines.joined(separator: "\n"), changed.joined(separator: "\n"), context: 1).hunks.count == 2)
    }
}

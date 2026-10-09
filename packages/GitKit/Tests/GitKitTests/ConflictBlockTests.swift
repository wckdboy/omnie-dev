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

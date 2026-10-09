// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import DesignKit

struct PaneLayoutTests {
    let all = ["files", "agent", "timeline", "terminal", "preview", "stage", "tools"]

    func standard() -> PaneLayout {
        PaneLayout(left: [.init(panels: ["files"])],
                   right: [.init(panels: ["agent", "timeline", "terminal", "preview", "stage", "tools"])],
                   bottom: [])
    }

    @Test func movesPanelsBetweenGroupsAndDocks() throws {
        var layout = standard()
        // Terminal to a new bottom group: it's shown there and gone from the right.
        layout.move("terminal", toNewGroupIn: .bottom)
        #expect(layout.location(of: "terminal")?.dock == .bottom)
        #expect(layout.right[0].panels == ["agent", "timeline", "preview", "stage", "tools"])
        #expect(layout.isShowing("terminal"))
        // Preview joins the terminal's group at the front.
        layout.move("preview", toGroup: layout.bottom[0].id, at: 0)
        #expect(layout.bottom[0].panels == ["preview", "terminal"] && layout.bottom[0].selected == "preview")
        // Files moves into the right group; the empty left dock disappears.
        layout.move("files", toGroup: layout.right[0].id)
        #expect(layout.left.isEmpty && !layout.isVisible(.left))
        // Reordering within a group.
        layout.move("files", toGroup: layout.right[0].id, at: 0)
        #expect(layout.right[0].panels.first == "files")
        layout.move("files", toGroup: layout.right[0].id, at: 3)
        #expect(layout.right[0].panels == ["agent", "timeline", "files", "stage", "tools"])
        // Splitting the terminal off into its own group, then again: the second time changes nothing.
        layout.move("terminal", toNewGroupIn: .bottom)
        #expect(layout.bottom.map(\.panels) == [["preview"], ["terminal"]])
        let before = layout
        layout.move("terminal", toNewGroupIn: .bottom)
        #expect(layout == before)
    }

    @Test func closesAndRevealsPanels() {
        var layout = standard()
        layout.reveal("preview")
        #expect(layout.right[0].selected == "preview")
        layout.close("preview")
        #expect(layout.right[0].selected == "terminal")
        #expect(layout.closed(from: all) == ["preview"])
        // A closed panel can come back as a group of its own, the others' selection untouched.
        let selected = layout.right[0].selected
        layout.move("preview", toNewGroupIn: .right, at: 0)
        #expect(layout.right.map(\.panels.first) == ["preview", "agent"] && layout.right[1].selected == selected)
        layout.close("preview")
        layout.close("files")
        #expect(layout.left.isEmpty)
        // A closed panel comes back in the right dock.
        layout.reveal("files")
        #expect(layout.location(of: "files")?.dock == .right && layout.isShowing("files"))
        // Revealing shows a hidden dock.
        layout.toggle(.right)
        #expect(!layout.isVisible(.right) && !layout.isShowing("agent"))
        layout.reveal("agent")
        #expect(layout.isVisible(.right) && layout.isShowing("agent"))
    }

    @Test func closesAWholeGroup() {
        var layout = standard()
        layout.move("terminal", toNewGroupIn: .bottom)
        layout.move("preview", toGroup: layout.bottom[0].id)
        layout.closeGroup(layout.bottom[0].id)
        #expect(layout.bottom.isEmpty && !layout.isVisible(.bottom))
        #expect(layout.closed(from: all) == ["terminal", "preview"])
        layout.reveal("terminal")
        #expect(layout.isShowing("terminal"))
    }

    @Test func resizesWithinLimits() {
        var layout = standard()
        layout.move("terminal", toNewGroupIn: .right)
        // Two groups sharing 600 pt; dragging the boundary 100 pt down.
        layout.resizeGroups(in: .right, after: 0, by: 100, length: 600)
        let total = layout.right.map(\.weight).reduce(0, +)
        #expect(abs(layout.right[0].weight / total * 600 - 400) < 0.001)
        // Never smaller than the minimum.
        layout.resizeGroups(in: .right, after: 0, by: 10_000, length: 600)
        #expect(abs(layout.right[1].weight / layout.right.map(\.weight).reduce(0, +) * 600 - 80) < 0.001)
        layout.setSize(.left, 50, maximum: 500)
        #expect(layout.leftWidth == PaneLayout.minSideWidth)
        layout.setSize(.right, 900, maximum: 500)
        #expect(layout.rightWidth == 500)
        layout.resetSize(.right)
        #expect(layout.rightWidth == PaneLayout.defaultRightWidth && layout.right.allSatisfy { $0.weight == 1 })
    }

    @Test func fitsSideDocksToTheWidth() {
        var layout = standard()
        #expect(layout.fittingSides(width: 1366, minEditor: 480) == [.left, .right])
        // 260 + 380 + 480 = 1120: one side only below that, the one shown last.
        #expect(layout.fittingSides(width: 1000, minEditor: 480) == [.right])
        layout.reveal("files")
        #expect(layout.fittingSides(width: 1000, minEditor: 480) == [.left])
        #expect(layout.fittingSides(width: 600, minEditor: 480) == [])
        layout.toggle(.left)
        #expect(layout.fittingSides(width: 1000, minEditor: 480) == [.right])
    }

    @Test func survivesEncodingAndRepairs() throws {
        var layout = standard()
        layout.move("stage", toNewGroupIn: .bottom)
        layout.toggle(.left)
        let decoded = try JSONDecoder().decode(PaneLayout.self, from: JSONEncoder().encode(layout))
        #expect(decoded == layout)
        // An app version without "stage", and a duplicate: repaired, nothing empty left behind.
        var broken = layout
        broken.left[0].panels.append("agent")
        broken.repair(known: all.filter { $0 != "stage" })
        #expect(broken.bottom.isEmpty)
        #expect(broken.left[0].panels == ["files", "agent"] && !broken.right[0].panels.contains("agent"))
    }
}

// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import EditorKit

struct MinimapTests {
    @Test func linesHaveIndentLengthAndStart() {
        let map = Minimap(text: "func a() {\n    return 1\n\t}\n   \n")
        #expect(map.lines == [
            .init(indent: 0, length: 10, start: 0),
            .init(indent: 4, length: 12, start: 11),
            .init(indent: 4, length: 5, start: 24),   // a tab is 4 columns
            .init(indent: 0, length: 0, start: 27),   // only spaces: nothing drawn
            .init(indent: 0, length: 0, start: 31),
        ])
        #expect(map.line(at: 0) == 0 && map.line(at: 11) == 1 && map.line(at: 15) == 1 && map.line(at: 30) == 3 && map.line(at: 999) == 4)
    }

    @Test func viewportAndTapsMapBothWays() {
        let map = Minimap(text: Array(repeating: "x", count: 100).joined(separator: "\n"))
        // 100 lines × 2 pt fit in a 600 pt map; the editor's content is 2000 pt, 500 visible.
        #expect(map.rowHeight(in: 600) == 2)
        let band = map.viewport(offset: 1000, contentHeight: 2000, visibleHeight: 500, mapHeight: 600)
        #expect(band.y == 100 && band.height == 50)
        // A tap at the band's middle scrolls back to the same place.
        #expect(map.offset(forMapY: 125, contentHeight: 2000, visibleHeight: 500, mapHeight: 600) == 1000)
        // Clamped at both ends.
        #expect(map.offset(forMapY: -10, contentHeight: 2000, visibleHeight: 500, mapHeight: 600) == 0)
        #expect(map.offset(forMapY: 900, contentHeight: 2000, visibleHeight: 500, mapHeight: 600) == 1500)
        // A long file is squeezed into the map.
        let long = Minimap(text: Array(repeating: "x", count: 3000).joined(separator: "\n"))
        #expect(long.rowHeight(in: 600) == 0.2)
    }
}

// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import ToolsKit

struct ColorToolsTests {
    typealias RGB = ColorTools.RGB

    @Test func contrast() throws {
        let black = try #require(RGB(hex: "#000")), white = try #require(RGB(hex: "#FFFFFF"))
        #expect(abs(ColorTools.contrast(black, white) - 21) < 0.01)
        #expect(ColorTools.rate(RGB(hex: "#767676")!, on: white).aaNormal)          // the classic 4.54:1
        #expect(!ColorTools.rate(RGB(hex: "#777777")!, on: white).aaNormal)
        #expect(ColorTools.rate(RGB(hex: "#949494")!, on: white).summary.hasSuffix("AA large text only"))
        #expect(RGB(hex: "#3DD6F533")?.a ?? 0 < 0.21 && RGB(hex: "#3dd6f5")?.hex == "#3DD6F5")
        #expect(RGB(hex: "nope") == nil)
    }

    @Test func tokensFromTheBrandFile() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../../brand/tokens.json").standardized
        let json = try String(contentsOf: url, encoding: .utf8)
        let tokens = ColorTools.tokens(json)
        let primary = try #require(tokens.first { $0.path == "dark.text.primary" })
        #expect(primary.hex == "#E6E8EB" && primary.group == "text" && primary.name == "primary")
        // PLAN §883: the shipped dark text passes AA on every dark surface.
        #expect(ColorTools.contrastProblems(tokens.filter { $0.theme == "dark" && $0.name != "tertiary" }).isEmpty)
        // Setting a token changes only that value.
        let edited = try #require(ColorTools.setting("dark.text.primary", to: "#FFFFFF", in: json))
        #expect(ColorTools.tokens(edited).first { $0.path == "dark.text.primary" }?.hex == "#FFFFFF")
        #expect(ColorTools.tokens(edited).first { $0.path == "light.text.primary" }?.hex == tokens.first { $0.path == "light.text.primary" }?.hex)
        #expect(edited.count == json.count)   // same length: one value swapped in place
    }

    @Test func dominantColors() {
        // 3/4 red, 1/4 blue, a few transparent pixels.
        var pixels: [UInt8] = []
        for _ in 0..<75 { pixels += [250, 10, 10, 255] }
        for _ in 0..<25 { pixels += [10, 10, 240, 255] }
        for _ in 0..<10 { pixels += [0, 255, 0, 0] }
        let colors = ColorTools.dominantColors(rgba: pixels, count: 4)
        #expect(colors.count == 2)
        #expect(colors[0].hex == "#FA0A0A" && colors[1].hex == "#0A0AF0")
    }
}

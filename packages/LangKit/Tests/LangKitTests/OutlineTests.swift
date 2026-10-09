// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import LangKit

struct OutlineTests {
    func names(_ text: String, _ language: Language) -> [String] {
        Outline.symbols(in: text, language: language).map { "\($0.kind.rawValue) \($0.name) @\($0.line)" }
    }

    @Test func typescript() {
        let ts = """
            import { a } from "./a";
            export interface User { name: string }
            export type Id = string;
            export enum Mode { A }
            export async function load(id: Id): Promise<User> {
              if (id) { return x; }
            }
            const total = (items: number[]): number => items.length;
            export default class Cart {
              private items: Item[] = [];
              add(item: Item): void {
                for (const i of this.items) {}
              }
              static async from(json: string): Promise<Cart> { return new Cart(); }
            }
            """
        #expect(names(ts, .typescript) == ["interface User @2", "type Id @3", "enum Mode @4", "function load @5", "function total @8",
                                           "class Cart @9", "method add @11", "method from @14"])
    }

    @Test func pythonSwiftCssHtml() {
        #expect(names("class Cart:\n    def add(self, x):\n        pass\n\nasync def main():\n    pass\n", .python)
                == ["class Cart @1", "function add @2", "function main @5"])
        #expect(names("@MainActor\nfinal class Model {\n    init(x: Int) {}\n    func run() {}\n}\nextension Model.Inner {}\nprotocol P {}\nenum E {}\n", .swift)
                == ["class Model @2", "function init @3", "function run @4", "class Model.Inner @6", "interface P @7", "enum E @8"])
        #expect(names("body {\n  margin: 0;\n}\n.card, .tile {\n}\n@media (x) {\n}\n", .css) == ["selector body @1", "selector .card, .tile @4"])
        #expect(names("<div id=\"app\"></div><canvas id='scene'>", .html) == ["element app @1", "element scene @1"])
    }

    @Test func offsetsPointAtTheName() {
        let text = "let a = 1;\nfunction go() {}\n"
        let symbol = Outline.symbols(in: text, language: .javascript)[0]
        #expect((text as NSString).substring(with: NSRange(location: symbol.offset, length: symbol.length)) == "go")
    }
}

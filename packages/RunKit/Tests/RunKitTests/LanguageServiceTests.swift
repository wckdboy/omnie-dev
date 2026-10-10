// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import RunKit

extension WebKitSuites {
@MainActor
struct LanguageServiceTests {
    let root: URL
    let math = "/** Adds two numbers. */\nexport function add(a: number, b: number): number {\n  return a + b;\n}\n"
    let main = "import { add } from \"./math\";\n\nconst total = add(1, 2);\nconsole.log(total, add(3, 4));\n"

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lang-\(UUID().uuidString)")
        for (path, text) in ["src/math.ts": math, "src/main.ts": main, "src/util.js": "export const twice = (n) => n * 2;\n"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func offset(of needle: String, in text: String, occurrence: Int = 1) -> Int {
        var range = text.startIndex..<text.endIndex
        var found = text.startIndex
        for _ in 0..<occurrence {
            let r = text.range(of: needle, range: range)!
            found = r.lowerBound
            range = r.upperBound..<text.endIndex
        }
        return text.utf16.distance(from: text.startIndex, to: found)
    }

    @Test func definitionReferencesAndQuickInfo() async throws {
        let service = try LanguageService(root: root)
        defer { service.stop() }
        let call = offset(of: "add", in: main, occurrence: 2)
        let definition = try await service.definition("src/main.ts", offset: call)
        #expect(definition.map(\.path) == ["src/math.ts"])
        #expect(definition.first?.line == 2 && definition.first?.preview.hasPrefix("export function add") == true)

        let references = try await service.references("src/main.ts", offset: call)
        #expect(Set(references.map(\.path)) == ["src/math.ts", "src/main.ts"])
        #expect(references.count == 4, "\(references.map(\.id))")   // declared, imported, two calls
        #expect(references.contains { $0.isDefinition && $0.path == "src/math.ts" })

        let info = try #require(try await service.quickInfo("src/main.ts", offset: call))
        #expect(info.signature.contains("add(a: number, b: number): number"))
        #expect(info.documentation == "Adds two numbers.")
    }

    @Test func renameAcrossFilesAndUnsavedText() async throws {
        let service = try LanguageService(root: root)
        defer { service.stop() }
        let decl = offset(of: "add", in: math)
        #expect(try await service.renameTarget("src/math.ts", offset: decl) == "add")
        let plan = try await service.rename("src/math.ts", offset: decl, to: "sum")
        #expect(plan.files == ["src/main.ts", "src/math.ts"])
        #expect(plan.edits.count == 4 && plan.edits.allSatisfy { $0.newText == "sum" })
        // Keywords can't be renamed, and say so.
        await #expect(throws: LanguageServiceError.self) { try await service.renameTarget("src/math.ts", offset: offset(of: "return", in: math)) }

        // Unsaved text: a new function in the editor is found before it's saved.
        let edited = main + "function late() { return add(5, 6); }\nlate();\n"
        try await service.update("src/main.ts", text: edited)
        let late = try await service.definition("src/main.ts", offset: offset(of: "late", in: edited, occurrence: 2))
        #expect(late.first?.line == 5)
    }

    @Test func completionsForMembersAndJavaScript() async throws {
        let service = try LanguageService(root: root)
        defer { service.stop() }
        let text = "const word = \"hi\";\nword.toUp"
        try await service.update("src/scratch.ts", text: text)
        let members = try await service.completions("src/scratch.ts", offset: (text as NSString).length)
        #expect(members.first?.name == "toUpperCase", "\(members.prefix(5).map(\.name))")
        #expect(members.first?.length == 4)   // replaces "toUp"
        let detail = try await service.completionDetails("src/scratch.ts", offset: (text as NSString).length, name: "toUpperCase")
        #expect(detail?.signature.contains("toUpperCase(): string") == true)

        // JavaScript files get answers too.
        let js = "import { twice } from \"./util.js\";\ntwi"
        try await service.update("src/use.js", text: js)
        let found = try await service.completions("src/use.js", offset: (js as NSString).length)
        #expect(found.contains { $0.name == "twice" })
    }
}
}

extension WebKitSuites {
@MainActor
struct PythonLanguageTests {
    let root: URL
    let geometry = "def area(width, height):\n    \"\"\"Width times height.\"\"\"\n    return width * height\n"
    let main = "from geometry import area\n\nprint(area(2, 3))\ntotal = area(4, 5)\n"

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pylang-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try geometry.write(to: root.appendingPathComponent("geometry.py"), atomically: true, encoding: .utf8)
        try main.write(to: root.appendingPathComponent("main.py"), atomically: true, encoding: .utf8)
    }

    func offset(of needle: String, in text: String, occurrence: Int = 1) -> Int {
        var range = text.startIndex..<text.endIndex
        var found = text.startIndex
        for _ in 0..<occurrence {
            let r = text.range(of: needle, range: range)!
            found = r.lowerBound
            range = r.upperBound..<text.endIndex
        }
        return text.utf16.distance(from: text.startIndex, to: found)
    }

    @Test func definitionReferencesInfoRenameAndCompletions() async throws {
        let service = try LanguageService(root: root, flavor: .python)
        defer { service.stop() }
        // Jedi loads with Pyodide: give a cold start on a slow machine its time.
        try await service.start(timeout: JSRunnerTests.pythonTimeout)
        let call = offset(of: "area", in: main, occurrence: 2)
        try await service.update("main.py", text: main)
        let definition = try await service.definition("main.py", offset: call)
        #expect(definition.map(\.path) == ["geometry.py"], "\(definition)")
        #expect(definition.first?.line == 1 && definition.first?.start == 4)

        let references = try await service.references("main.py", offset: call)
        #expect(Set(references.map(\.path)) == ["geometry.py", "main.py"], "\(references)")
        #expect(references.count == 4)
        #expect(references.contains { $0.isDefinition && $0.path == "geometry.py" })

        let info = try #require(try await service.quickInfo("main.py", offset: call))
        #expect(info.signature.contains("area(width, height)"), "\(info.signature)")
        #expect(info.documentation == "Width times height.")

        let plan = try await service.rename("main.py", offset: call, to: "surface")
        #expect(plan.files == ["geometry.py", "main.py"] && plan.edits.count == 4)

        let typed = main + "count = 10\ncount.bit_"
        try await service.update("main.py", text: typed)
        let found = try await service.completions("main.py", offset: (typed as NSString).length)
        #expect(found.first?.name == "bit_length", "\(found.prefix(5).map(\.name))")
        #expect(found.first?.length == 4)
    }
}
}

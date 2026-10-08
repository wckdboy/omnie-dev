import Foundation
import Testing
@testable import WorkspaceKit

struct FileTreeTests {
    func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omnie-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("src/lib"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".git/objects"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("node_modules/three"), withIntermediateDirectories: true)
        try "readme".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "a".write(to: root.appendingPathComponent("b.js"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("src/main.ts"), atomically: true, encoding: .utf8)
        try "y".write(to: root.appendingPathComponent("src/lib/util.ts"), atomically: true, encoding: .utf8)
        return root
    }

    @Test func scansDirectoriesFirstAndSkipsIgnored() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = try FileTree.scan(root)
        #expect(tree.children?.map(\.name) == ["src", "b.js", "README.md"])
        let src = try #require(tree.children?.first)
        #expect(src.children?.map(\.name) == ["lib", "main.ts"])
    }

    @Test func respectsDepthLimit() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = try FileTree.scan(root, maxDepth: 1)
        let src = try #require(tree.children?.first)
        #expect(src.isDirectory)
        #expect(src.children == [])
    }

    @Test func loadRejectsBinaryAndRoundTripsText() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("blob.bin")
        try Data([0x89, 0x50, 0x00, 0x01]).write(to: bin)
        #expect(throws: TextFile.LoadError.binary) { try TextFile.load(bin) }

        let file = root.appendingPathComponent("b.js")
        try TextFile.save("const x = 1\n", to: file)
        #expect(try TextFile.load(file) == "const x = 1\n")
    }

    @Test func lineColumn() {
        let text = "ab\ncde\n"
        let idx = text.index(text.startIndex, offsetBy: 5) // "e"
        #expect(TextPosition.lineColumn(in: text, at: idx) == (2, 3))
        #expect(TextPosition.lineColumn(in: text, at: text.startIndex) == (1, 1))
    }
}

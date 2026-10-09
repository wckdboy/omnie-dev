// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import WorkspaceKit

struct FuzzyMatchTests {
    let files = ["src/components/UserProfile.tsx", "src/utils/user.ts", "README.md", "src/user/profile/index.ts",
                 "tests/user.test.ts", "docs/use-cases.md", "packages/upload/src/uploader.ts"]

    @Test func ranksLikeAnEditor() {
        #expect(FuzzyMatch.rank("userprof", files).first == "src/components/UserProfile.tsx")
        #expect(FuzzyMatch.rank("user.ts", files).first == "src/utils/user.ts")
        #expect(FuzzyMatch.rank("readme", files) == ["README.md"])
        #expect(FuzzyMatch.rank("upt", files).contains("packages/upload/src/uploader.ts"))
        #expect(FuzzyMatch.score("xyz", "src/user.ts") == nil)
        #expect(FuzzyMatch.rank("", files).count == files.count)
    }
}

struct ProjectSearchTests {
    @Test func findsWithLinesColumnsAndRanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-\(UUID().uuidString)")
        for (path, text) in ["a.ts": "const total = 1;\nlet x = Total + total;\n", "b/c.md": "👩‍💻 total\n", "node_modules/x.js": "total"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        #expect(ProjectSearch.files(in: root) == ["a.ts", "b/c.md"])
        let hits = ProjectSearch.search("total", in: root)
        #expect(hits.map { "\($0.path):\($0.line):\($0.column)" } == ["a.ts:1:7", "a.ts:2:9", "a.ts:2:17", "b/c.md:1:3"])
        #expect(hits[0].text == "const total = 1;")
        #expect(hits[0].range == NSRange(location: 6, length: 5))
        #expect(ProjectSearch.search("Total", in: root, caseSensitive: true).count == 1)
    }
}

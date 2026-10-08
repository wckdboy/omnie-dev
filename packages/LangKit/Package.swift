// swift-tools-version: 6.2
// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let package = Package(
    name: "LangKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "LangKit", targets: ["LangKit"])],
    dependencies: [
        // Same runtime as the editor engine; tests use it to prove each grammar loads.
        .package(url: "https://github.com/tree-sitter/tree-sitter", exact: "0.26.13"),
    ],
    targets: [
        // Generated grammar sources, vendored by scripts/vendor-grammars.py.
        .target(name: "TreeSitterGrammars", cSettings: [
            // typescript/common/scanner.h includes tree_sitter/parser.h from its grammar's src.
            .headerSearchPath("typescript/typescript/src"),
            .unsafeFlags(["-w"]),
        ]),
        .target(name: "LangKit", dependencies: ["TreeSitterGrammars"], resources: [.copy("Resources/queries")]),
        .testTarget(name: "LangKitTests", dependencies: [
            "LangKit",
            .product(name: "TreeSitter", package: "tree-sitter"),
        ]),
    ]
)

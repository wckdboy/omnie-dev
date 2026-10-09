// swift-tools-version: 6.2
// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let package = Package(
    name: "EditorKit",
    platforms: [.iOS(.v26)],
    products: [.library(name: "EditorKit", targets: ["EditorKit"])],
    dependencies: [
        // The Runestone-derived Core Text engine (PLAN §5.1, §27.3), pinned by exact tag.
        .package(url: "https://github.com/wckdboy/omnie-dev-editor-engine", exact: "0.6.3"),
        .package(path: "../LangKit"),
        .package(path: "../DesignKit"),
    ],
    targets: [
        .target(name: "EditorKit", dependencies: [
            .product(name: "Runestone", package: "omnie-dev-editor-engine"),
            "LangKit",
            "DesignKit",
        ]),
        .testTarget(name: "EditorKitTests", dependencies: ["EditorKit"]),
    ]
)

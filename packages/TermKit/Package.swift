// swift-tools-version: 6.2
// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let package = Package(
    name: "TermKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "TermKit", targets: ["TermKit"])],
    targets: [
        .target(name: "TermKit"),
        .testTarget(name: "TermKitTests", dependencies: ["TermKit"]),
    ]
)

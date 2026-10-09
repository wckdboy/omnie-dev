// swift-tools-version: 6.2
// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let package = Package(
    name: "AgentKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "AgentKit", targets: ["AgentKit"])],
    dependencies: [
        .package(path: "../ModelKit"),
        .package(path: "../PolicyKit"),
    ],
    targets: [
        .target(name: "AgentKit", dependencies: ["ModelKit", "PolicyKit"]),
        .testTarget(name: "AgentKitTests", dependencies: ["AgentKit"]),
    ]
)

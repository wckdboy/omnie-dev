// swift-tools-version: 6.2
// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let package = Package(
    name: "ModelKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "ModelKit", targets: ["ModelKit"])],
    targets: [
        .target(name: "ModelKit"),
        .testTarget(name: "ModelKitTests", dependencies: ["ModelKit"]),
    ]
)

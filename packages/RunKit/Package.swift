// swift-tools-version: 6.2
// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let package = Package(
    name: "RunKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "RunKit", targets: ["RunKit"])],
    targets: [
        // JS/sucrase.js comes from scripts/vendor-runkit.sh.
        .target(name: "RunKit", resources: [.copy("JS")]),
        .testTarget(name: "RunKitTests", dependencies: ["RunKit"]),
    ]
)

// swift-tools-version: 6.2
// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

/// Forge adapters: pull/merge requests and their checks (PLAN.md §9.11). Optional by design:
/// nothing in git depends on it, and it knows nothing of git beyond a remote's URL.
let package = Package(
    name: "HostKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "HostKit", targets: ["HostKit"])],
    targets: [
        .target(name: "HostKit"),
        .testTarget(name: "HostKitTests", dependencies: ["HostKit"]),
    ]
)

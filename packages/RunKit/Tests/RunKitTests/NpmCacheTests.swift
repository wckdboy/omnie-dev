// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Testing
@testable import RunKit

struct SemverTests {
    func matches(_ range: String, _ version: String) -> Bool { SemverRange(range)!.contains(Semver(version)!) }

    @Test func ranges() {
        #expect(matches("^1.2.3", "1.9.0") && !matches("^1.2.3", "2.0.0") && !matches("^1.2.3", "1.2.2"))
        #expect(matches("^0.2.3", "0.2.9") && !matches("^0.2.3", "0.3.0"))
        #expect(matches("^0.0.3", "0.0.3") && !matches("^0.0.3", "0.0.4"))
        #expect(matches("~1.2.3", "1.2.9") && !matches("~1.2.3", "1.3.0"))
        #expect(matches("1.x", "1.4.0") && !matches("1.x", "2.0.0"))
        #expect(matches(">=1.2 <2", "1.5.0") && !matches(">=1.2 <2", "2.0.0"))
        #expect(matches("1.2 - 1.4", "1.4.7") && !matches("1.2 - 1.4", "1.5.0"))
        #expect(matches("^1 || ^3", "3.1.0") && !matches("^1 || ^3", "2.0.0"))
        #expect(matches("*", "9.9.9") && matches("", "0.1.0") && matches("latest", "1.0.0"))
        #expect(!matches("^1.0.0", "1.1.0-beta.1") && matches("^1.1.0-beta.0", "1.1.0-beta.1"))
        #expect(Semver("1.0.0-alpha")! < Semver("1.0.0-alpha.1")! && Semver("1.0.0-rc.1")! < Semver("1.0.0")!)
        #expect(SemverRange("^18.2.0")!.best(of: ["18.1.0", "18.3.1", "19.0.0", "18.2.0"].compactMap(Semver.init))?.description == "18.3.1")
        #expect(SemverRange("github:user/repo") == nil)
    }
}

/// Packages made with `tar`, served by a fake registry.
struct FakeRegistry {
    var responses: [String: Data] = [:]
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("npm-fake-\(UUID().uuidString)")

    mutating func publish(_ name: String, versions: [String: [String: String]], latest: String? = nil, dependencies: [String: String] = [:],
                          corrupt: Bool = false) throws {
        var meta: [String: Any] = [:]
        for (version, files) in versions {
            let dir = work.appending(path: "\(name)-\(version)/package")
            var files = files
            // Like a real tarball, package.json lists the dependencies too.
            if var manifest = try JSONSerialization.jsonObject(with: Data(files["package.json", default: "{}"].utf8)) as? [String: Any] {
                manifest["dependencies"] = dependencies
                files["package.json"] = String(decoding: try JSONSerialization.data(withJSONObject: manifest), as: UTF8.self)
            }
            for (path, text) in files {
                let url = dir.appending(path: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            let tgz = work.appending(path: "\(name.replacingOccurrences(of: "/", with: "-"))-\(version).tgz")
            let tar = Process()
            tar.executableURL = URL(filePath: "/usr/bin/tar")
            tar.arguments = ["-czf", tgz.path, "-C", dir.deletingLastPathComponent().path, "package"]
            try tar.run(); tar.waitUntilExit()
            var data = try Data(contentsOf: tgz)
            let integrity = "sha512-" + Data(SHA512.hash(data: data)).base64EncodedString()
            if corrupt { data[data.count - 9] ^= 0xff }
            let url = "https://fake.registry/tarballs/\(tgz.lastPathComponent)"
            responses[url] = data
            meta[version] = ["dist": ["tarball": url, "integrity": integrity], "dependencies": dependencies]
        }
        let doc: [String: Any] = ["name": name, "dist-tags": ["latest": latest ?? versions.keys.sorted().last!], "versions": meta]
        responses["https://fake.registry/" + name.replacingOccurrences(of: "/", with: "%2f")] = try JSONSerialization.data(withJSONObject: doc)
    }

    func cache(_ root: URL) -> NpmCache {
        let responses = responses
        return NpmCache(root: root, registry: URL(string: "https://fake.registry")!) { url in
            guard let data = responses[url.absoluteString] else { throw URLError(.fileDoesNotExist) }
            return data
        }
    }

    static func standard() throws -> FakeRegistry {
        var registry = FakeRegistry()
        let esm = [
            "package.json": #"{ "name": "esm-lib", "type": "module", "exports": { ".": { "import": "./dist/index.js", "require": "./dist/index.cjs" }, "./extra": "./dist/extra.js" } }"#,
            "dist/index.js": "import { double } from \"cjs-lib\";\nexport const quadruple = (n) => double(double(n));\nexport default \"esm default\";\n",
            "dist/extra.js": "export const extra = \"extra\";\n",
        ]
        try registry.publish("esm-lib", versions: ["1.0.0": esm, "1.2.0": esm, "2.0.0": esm], latest: "1.2.0", dependencies: ["cjs-lib": "^2.0.0"])
        try registry.publish("cjs-lib", versions: ["2.1.0": [
            "package.json": #"{ "name": "cjs-lib", "main": "lib/index" }"#,
            "lib/index.js": "'use strict';\nmodule.exports = require('./impl');\n",
            "lib/impl.js": "const path = require('path');\nexports.double = function (n) { return n * 2; };\nexports.mode = process.env.NODE_ENV;\nexports.hasPath = typeof path === 'object';\n",
        ]])
        try registry.publish("@scope/babel", versions: ["1.0.0": [
            "package.json": #"{ "name": "@scope/babel", "main": "index.js" }"#,
            "index.js": "\"use strict\";\nObject.defineProperty(exports, \"__esModule\", { value: true });\nexports.default = function hi() { return \"hi\"; };\nexports.named = 3;\n",
        ]])
        try registry.publish("broken", versions: ["1.0.0": ["package.json": "{}", "index.js": "x"]], corrupt: true)
        return registry
    }
}

struct NpmCacheTests {
    let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("npm-cache-\(UUID().uuidString)")

    @Test func installsTheBestVersionAndItsDependencies() async throws {
        let cache = try FakeRegistry.standard().cache(cacheRoot)
        let installed = try await cache.install("esm-lib", range: "^1.0.0")
        #expect(installed == [.init(name: "esm-lib", version: "1.2.0"), .init(name: "cjs-lib", version: "2.1.0")])
        #expect(FileManager.default.fileExists(atPath: cacheRoot.appending(path: "esm-lib/1.2.0/dist/index.js").path))
        #expect(NpmCache.all(in: cacheRoot).keys.sorted() == ["cjs-lib", "esm-lib"])
        // Cached now: nothing new.
        #expect(try await cache.install("esm-lib", range: "^1.1.0").isEmpty)
        // "latest" is the dist-tag, not the highest version.
        _ = try await cache.install("esm-lib")
        #expect(NpmCache.versions(of: "esm-lib", in: cacheRoot) == [Semver("1.2.0")!])
        try await cache.install("@scope/babel", range: "1")
        #expect(NpmCache.all(in: cacheRoot)["@scope/babel"] == [Semver("1.0.0")!])
    }

    @Test func refusesBadPackages() async throws {
        let cache = try FakeRegistry.standard().cache(cacheRoot)
        await #expect(throws: NpmCache.Failure.integrity("broken@1.0.0")) { try await cache.install("broken") }
        await #expect(throws: NpmCache.Failure.notFound("nope")) { try await cache.install("nope") }
        await #expect(throws: NpmCache.Failure.noMatchingVersion("esm-lib", "^9")) { try await cache.install("esm-lib", range: "^9") }
        #expect(NpmCache.all(in: cacheRoot).isEmpty)
    }

    @Test func tarPathsCantEscape() {
        #expect(Tarball.sanitize("package/lib/a.js") == "lib/a.js")
        #expect(Tarball.sanitize("package/../../etc/passwd") == nil)
        #expect(Tarball.sanitize("/abs/x") == nil)
        #expect(Tarball.sanitize("package") == nil)
    }

    @Test func importMapAndCommonJS() async throws {
        let cache = try FakeRegistry.standard().cache(cacheRoot)
        try await cache.install("esm-lib", range: "^1.0.0")
        try await cache.install("@scope/babel", range: "^1.0.0")
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("npm-project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{ "dependencies": { "esm-lib": "^1.0.0" }, "devDependencies": { "@scope/babel": "*" } }"#
            .write(to: project.appending(path: "package.json"), atomically: true, encoding: .utf8)
        let map = NpmModules.importMap(project: project, cache: cacheRoot)
        #expect(map["esm-lib"] == "omnie-run://local/__omnie/npm/esm-lib/1.2.0/dist/index.js")
        #expect(map["esm-lib/extra"] == "omnie-run://local/__omnie/npm/esm-lib/1.2.0/dist/extra.js")
        #expect(map["cjs-lib"] == "omnie-run://local/__omnie/npm/cjs-lib/2.1.0/lib/index.js")
        #expect(map["@scope/babel"] == "omnie-run://local/__omnie/npm/@scope/babel/1.0.0/index.js")
        let names = NpmModules.exportNames(try String(contentsOf: cacheRoot.appending(path: "cjs-lib/2.1.0/lib/index.js"), encoding: .utf8),
                                           file: "lib/index.js", folder: cacheRoot.appending(path: "cjs-lib/2.1.0"), depth: 0)
        #expect(names == ["double", "mode", "hasPath"])
        #expect(NpmModules.isCommonJS("exports.a = 1;\nconst b = require('b');") && !NpmModules.isCommonJS("import x from 'y';\nexport const a = 1;"))
        #expect(NpmModules.exportNames("module.exports = { a, b: 1, c() { return {x: 1} }, d };", file: "x.js", folder: cacheRoot, depth: 0) == ["a", "b", "c", "d"])
    }
}

extension WebKitSuites {
@MainActor
struct NpmRunTests {
    @Test func aProjectImportsCachedPackages() async throws {
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("npm-run-\(UUID().uuidString)")
        let cache = try FakeRegistry.standard().cache(cacheRoot)
        try await cache.install("esm-lib", range: "^1.0.0")
        try await cache.install("@scope/babel", range: "^1.0.0")
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("npm-run-project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{ "dependencies": { "esm-lib": "^1.0.0", "@scope/babel": "^1.0.0" } }"#
            .write(to: project.appending(path: "package.json"), atomically: true, encoding: .utf8)
        try """
            import esmDefault, { quadruple } from "esm-lib";
            import { extra } from "esm-lib/extra";
            import cjs, { double, mode, hasPath } from "cjs-lib";
            import hi, { named } from "@scope/babel";
            console.log(esmDefault, quadruple(3), extra, double(4), cjs.double(5), mode, hasPath, hi(), named);
            """.write(to: project.appending(path: "main.ts"), atomically: true, encoding: .utf8)
        NpmCache.sharedRoot = cacheRoot
        defer { NpmCache.sharedRoot = nil }
        let result = await (try JSRunner(root: project)).runFile("main.ts")
        #expect(result.output.map(\.text) == ["esm default 12 extra 8 10 production true hi 3"], "\(result.report)")
    }
}
}


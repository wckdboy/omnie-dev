// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Testing
@testable import RunKit

struct PEP440Tests {
    func ok(_ spec: String, _ v: String) -> Bool { PySpecifier(spec)!.contains(PyVersion(v)!) }

    @Test func versionsAndSpecifiers() {
        #expect(PyVersion("1.0")! == PyVersion("1.0.0")!)
        #expect(PyVersion("1.0.dev1")! < PyVersion("1.0a1")! && PyVersion("1.0a1")! < PyVersion("1.0rc1")!)
        #expect(PyVersion("1.0rc1")! < PyVersion("1.0")! && PyVersion("1.0")! < PyVersion("1.0.post1")!)
        #expect(PyVersion("2.10")! > PyVersion("2.9")! && PyVersion("1!0.1")! > PyVersion("99.0")!)
        #expect(ok(">=1.2,<2", "1.9.3") && !ok(">=1.2,<2", "2.0"))
        #expect(ok("~=3.1", "3.9") && !ok("~=3.1", "4.0") && ok("~=3.1.2", "3.1.9") && !ok("~=3.1.2", "3.2.0"))
        #expect(ok("==2.*", "2.4.1") && !ok("==2.*", "3.0") && ok("!=1.5", "1.6"))
        #expect(!ok(">=1", "2.0b1") && ok(">=2.0b1", "2.0b2"))
        #expect(ok("", "0.1"))
    }

    @Test func requirementsAndMarkers() {
        let r = PyRequirement("Typing_Extensions[dev] (>=4.0) ; python_version >= \"3.8\"")!
        #expect(r.name == "typing-extensions" && r.specifier == ">=4.0" && r.appliesHere)
        #expect(PyRequirement("pytest>=7 ; extra == \"test\"")?.appliesHere == false)
        #expect(PyRequirement("colorama ; sys_platform == \"win32\"")?.appliesHere == false)
        #expect(PyRequirement("tomli>=1.1.0; python_version < \"3.11\"")?.appliesHere == false)
        #expect(PyRequirement("exceptiongroup; (python_version < '3.11') or platform_system == 'Emscripten'")?.appliesHere == true)
        #expect(PyRequirement("requests  # web")?.name == "requests")
        #expect(PyCache.lock["numpy"]?.file.hasSuffix(".whl") == true)
    }

    @Test func projectRequirementsFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pyreq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "[build-system]\nrequires = [\"hatchling\"]\n\n[project]\nname = \"x\"\ndependencies = [\n  \"numpy>=2\",\n  'attrs',\n]\n\n[tool.x]\ndependencies = [\"nope\"]\n"
            .write(to: root.appending(path: "pyproject.toml"), atomically: true, encoding: .utf8)
        #expect(PyCache.projectRequirements(root).map(\.name) == ["numpy", "attrs"])
        try "# deps\nrequests==2.32.3\n-r other.txt\ngit+https://x/y.git\n\nrich>=13 ; python_version >= '3.8'\n"
            .write(to: root.appending(path: "requirements.txt"), atomically: true, encoding: .utf8)
        #expect(PyCache.projectRequirements(root).map(\.name) == ["requests", "rich"])
    }
}

/// A fake PyPI serving wheels made with `zip`.
struct FakePyPI {
    var responses: [String: Data] = [:]
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("pypi-fake-\(UUID().uuidString)")

    mutating func publish(_ name: String, _ version: String, module: String, source: String, requires: [String] = [], corrupt: Bool = false) throws {
        let dir = work.appending(path: "\(name)-\(version)")
        let dist = "\(module)-\(version).dist-info"
        let files = [
            "\(module)/__init__.py": source,
            "\(dist)/METADATA": "Metadata-Version: 2.1\nName: \(name)\nVersion: \(version)\n" + requires.map { "Requires-Dist: \($0)\n" }.joined(),
            "\(dist)/WHEEL": "Wheel-Version: 1.0\nGenerator: test\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
            "\(dist)/top_level.txt": module + "\n",
            "\(dist)/RECORD": "",
        ]
        for (path, text) in files {
            let url = dir.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let filename = "\(module)-\(version)-py3-none-any.whl"
        let zip = Process()
        zip.executableURL = URL(filePath: "/usr/bin/zip")
        zip.currentDirectoryURL = dir
        zip.arguments = ["-qr", work.appending(path: filename).path, "."]
        try zip.run(); zip.waitUntilExit()
        var data = try Data(contentsOf: work.appending(path: filename))
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if corrupt { data[10] ^= 0xff }
        let url = "https://fake.pypi/files/\(filename)"
        responses[url] = data
        let file: [String: Any] = ["filename": filename, "url": url, "packagetype": "bdist_wheel", "digests": ["sha256": sha]]
        let key = "https://fake.pypi/\(name)/json"
        var meta = (try? JSONSerialization.jsonObject(with: responses[key] ?? Data()) as? [String: Any]) ?? ["releases": [String: Any]()]
        var releases = meta["releases"] as! [String: Any]
        releases[version] = [file]
        meta["releases"] = releases
        responses[key] = try JSONSerialization.data(withJSONObject: meta)
        responses["https://fake.pypi/\(name)/\(version)/json"] = try JSONSerialization.data(withJSONObject: ["info": ["requires_dist": requires]])
    }

    func cache(_ root: URL) -> PyCache {
        let responses = responses
        return PyCache(root: root, pypi: URL(string: "https://fake.pypi")!) { url in
            guard let data = responses[url.absoluteString] else { throw URLError(.fileDoesNotExist) }
            return data
        }
    }

    static func standard() throws -> FakePyPI {
        var pypi = FakePyPI()
        try pypi.publish("greetlib", "1.0.0", module: "greetlib", source: "def hello(n):\n    return 'old'\n")
        try pypi.publish("greetlib", "1.4.0", module: "greetlib", source: "from shoutlib import shout\ndef hello(n):\n    return shout('hello ' + n)\n",
                         requires: ["shoutlib>=0.2", "pytest ; extra == 'test'"])
        try pypi.publish("greetlib", "2.0.0", module: "greetlib", source: "def hello(n):\n    return 'new'\n")
        try pypi.publish("shoutlib", "0.3.0", module: "shoutlib", source: "def shout(s):\n    return s.upper() + '!'\n")
        try pypi.publish("badlib", "1.0.0", module: "badlib", source: "", corrupt: true)
        return pypi
    }
}

struct PyCacheTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pycache-\(UUID().uuidString)")

    @Test func installsPureWheelsWithDependencies() async throws {
        let cache = try FakePyPI.standard().cache(root)
        let installed = try await cache.install(PyRequirement("greetlib>=1.1,<2")!)
        #expect(installed == [.init(name: "greetlib", version: "1.4.0"), .init(name: "shoutlib", version: "0.3.0")])
        #expect(try await cache.install(PyRequirement("greetlib~=1.4")!).isEmpty)
        await #expect(throws: PyCache.Failure.integrity("badlib 1.0.0")) { try await cache.install(PyRequirement("badlib")!) }
        await #expect(throws: PyCache.Failure.notFound("nope")) { try await cache.install(PyRequirement("nope")!) }
        await #expect(throws: PyCache.Failure.noWheel("greetlib", ">=3")) { try await cache.install(PyRequirement("greetlib>=3")!) }
    }
}

extension WebKitSuites {
@MainActor
struct PyCacheRunTests {
    @Test func aScriptImportsCachedWheels() async throws {
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("pycache-run-\(UUID().uuidString)")
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("pycache-project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "greetlib>=1.1,<2\n".write(to: project.appending(path: "requirements.txt"), atomically: true, encoding: .utf8)
        try "import greetlib\nprint(greetlib.hello('ada'))\n".write(to: project.appending(path: "main.py"), atomically: true, encoding: .utf8)
        try await FakePyPI.standard().cache(cacheRoot).installProject(project)
        PyCache.sharedRoot = cacheRoot
        defer { PyCache.sharedRoot = nil }
        let result = await (try JSRunner(root: project)).runPython("main.py", timeout: JSRunnerTests.pythonTimeout)
        #expect(result.output.map(\.text) == ["HELLO ADA!"], "\(result.report)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OMNIE_PYPI_REAL"] != nil))
    func realPackages() async throws {
        let cacheRoot = URL(filePath: "/tmp/claude-501/pypi-real-cache")
        let cache = PyCache(root: cacheRoot) { url in
            let (data, response) = try await URLSession.shared.data(from: url)
            if (response as? HTTPURLResponse)?.statusCode == 404 { throw URLError(.fileDoesNotExist) }
            return data
        }
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("pypi-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "numpy\npython-slugify>=8\ntabulate\nattrs>=23\n".write(to: project.appending(path: "requirements.txt"), atomically: true, encoding: .utf8)
        let installed = try await cache.installProject(project) { print($0) }
        print("installed", installed.map { "\($0.name) \($0.version)" })
        try """
            import numpy as np, attrs
            from slugify import slugify
            from tabulate import tabulate
            @attrs.define
            class P:
                x: int
            print(int(np.arange(5).sum()), slugify("Hello Wörld!"), P(3).x)
            print(tabulate([[1, 2]], headers=["a", "b"], tablefmt="plain").splitlines()[0].split())
            """.write(to: project.appending(path: "main.py"), atomically: true, encoding: .utf8)
        PyCache.sharedRoot = cacheRoot
        defer { PyCache.sharedRoot = nil }
        let result = await (try JSRunner(root: project)).runFile("main.py")
        print(result.report)
        #expect(result.output.map(\.text) == ["10 hello-world 3", "['a', 'b']"])
    }
}
}

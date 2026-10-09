// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import GitKit

struct LFSPointerTests {
    @Test func pointersRoundTrip() {
        let content = Data("hello lfs\n".utf8)
        let pointer = LFS.Pointer(content: content)
        #expect(pointer.size == 10 && pointer.oid.count == 64)
        #expect(LFS.Pointer.parse(Data(pointer.text.utf8)) == pointer)
        #expect(LFS.Pointer.parse(content) == nil)
        #expect(LFS.Pointer.parse(Data("version https://git-lfs.github.com/spec/v1\noid sha256:xyz\nsize 1\n".utf8)) == nil)
    }

    @Test func endpointsFromRemotes() {
        #expect(LFS.endpoint(for: "https://github.com/me/app.git")?.absoluteString == "https://github.com/me/app.git/info/lfs")
        #expect(LFS.endpoint(for: "https://codeberg.org/me/app")?.absoluteString == "https://codeberg.org/me/app.git/info/lfs")
        #expect(LFS.endpoint(for: "git@gitlab.com:me/app.git")?.absoluteString == "https://gitlab.com/me/app.git/info/lfs")
        #expect(LFS.endpoint(for: "ssh://git@forgejo.example.net/me/app.git")?.absoluteString == "https://forgejo.example.net/me/app.git/info/lfs")
    }
}

/// The filter and the batch API against a small Git LFS server (basic transfers, Basic auth).
final class LFSRepoTests {
    let root: URL
    let me = Signature(name: "Pad", email: "pad@example.com")
    let port = Int.random(in: 30000...60000)
    var server: Process?

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lfs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { server?.terminate() }

    static let serverScript = #"""
    import base64, json, sys
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    port = int(sys.argv[1]); store = {}
    AUTH = "Basic " + base64.b64encode(b"pad:secret-token").decode()
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def send(self, code, body=b"", ctype="application/vnd.git-lfs+json"):
            self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
        def do_POST(self):
            if self.headers.get("Authorization") != AUTH: return self.send(401, b'{"message":"credentials"}')
            req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            base = "http://127.0.0.1:%d/objects/" % port
            out = []
            for o in req["objects"]:
                if req["operation"] == "download":
                    out.append(dict(o, actions={"download": {"href": base + o["oid"], "header": {"X-Ticket": "t"}}}) if o["oid"] in store else dict(o, error={"code": 404, "message": "not found"}))
                else:
                    out.append(o if o["oid"] in store else dict(o, actions={"upload": {"href": base + o["oid"], "header": {"X-Ticket": "t"}}}))
            self.send(200, json.dumps({"transfer": "basic", "objects": out}).encode())
        def do_PUT(self):
            if self.headers.get("X-Ticket") != "t": return self.send(403)
            store[self.path.rsplit("/", 1)[1]] = self.rfile.read(int(self.headers["Content-Length"])); self.send(200)
        def do_GET(self):
            oid = self.path.rsplit("/", 1)[1]
            if self.headers.get("X-Ticket") != "t" or oid not in store: return self.send(404)
            self.send(200, store[oid], "application/octet-stream")
    ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
    """#

    func startServer() throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["python3", "-c", Self.serverScript, String(port)]
        try process.run()
        server = process
        for _ in 0..<100 {
            if (try? Data(contentsOf: URL(string: "http://127.0.0.1:\(port)/objects/none")!)) != nil || connects() { return }
            usleep(50_000)
        }
    }

    func connects() -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/objects/none")!)
        request.timeoutInterval = 0.2
        let done = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: request) { _, response, _ in ok = response != nil; done.signal() }.resume()
        done.wait()
        return ok
    }

    func git(_ args: String..., in dir: URL) throws -> String { try SSHTests.git(args, in: dir) }

    @Test func theFilterStoresObjectsAndCommitsPointers() async throws {
        let dir = root.appendingPathComponent("repo")
        let repo = try Repository.create(at: dir)
        try "*.bin filter=lfs diff=lfs merge=lfs -text\n".write(to: dir.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        let content = Data((0..<5000).map { UInt8($0 % 251) })
        try content.write(to: dir.appendingPathComponent("model.bin"))
        try await repo.commitAll(message: "Add a model\n", author: me)
        #expect(await repo.usesLFS())

        // In git: a pointer. In .git/lfs: the object. In the folder: the file. Status: clean.
        let committed = try git("cat-file", "-p", "HEAD:model.bin", in: dir)
        let pointer = try #require(LFS.Pointer.parse(Data((committed + "\n").utf8)))
        #expect(pointer == LFS.Pointer(content: content))
        #expect(try Data(contentsOf: LFS.objectURL(pointer.oid, gitDir: dir.appendingPathComponent(".git"))) == content)
        #expect(try await repo.status().entries.isEmpty)
        #expect(try await repo.lfsPointers() == ["model.bin": pointer])

        // An edit shows as a change; checking out brings the stored content back.
        try Data("changed".utf8).write(to: dir.appendingPathComponent("model.bin"))
        #expect(try await repo.status().entries.map(\.path) == ["model.bin"])
        try await repo.checkoutPaths(["model.bin"])
        #expect(try Data(contentsOf: dir.appendingPathComponent("model.bin")) == content)
    }

    @Test func pushAndPullThroughTheBatchAPI() async throws {
        try startServer()
        let auth = RemoteAuth(credential: { _ in .token(username: "pad", token: "secret-token") }, checkHostKey: { _ in .trusted })
        let lfsURL = "http://127.0.0.1:\(port)/repo.git"

        // One clone commits a large file and uploads its object.
        let a = root.appendingPathComponent("a")
        let repoA = try Repository.create(at: a)
        try "*.glb filter=lfs -text\n".write(to: a.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        let model = Data((0..<20_000).map { UInt8(($0 * 7) % 256) })
        try model.write(to: a.appendingPathComponent("scene.glb"))
        try await repoA.commitAll(message: "Scene\n", author: me)
        try await repoA.addRemote(name: "origin", url: lfsURL)
        #expect(try await repoA.lfsPush(remote: "origin", auth: auth) == 1)
        #expect(try await repoA.lfsPush(remote: "origin", auth: auth) == 0) // already there

        // Another repo with the same commits but no object: the file is a pointer until it pulls.
        let b = root.appendingPathComponent("b")
        let repoB = try await Repository.clone(from: a.path, to: b, auth: auth)
        try await repoB.setRemoteURL("origin", lfsURL)
        #expect(LFS.Pointer.parse(try Data(contentsOf: b.appendingPathComponent("scene.glb"))) != nil)
        #expect(try await repoB.lfsPull(remote: "origin", auth: auth) == 1)
        #expect(try Data(contentsOf: b.appendingPathComponent("scene.glb")) == model)
        #expect(try await repoB.status().entries.isEmpty)

        // Wrong credentials say so (with the object gone, so the pull has to ask).
        try FileManager.default.removeItem(at: b.appendingPathComponent(".git/lfs"))
        let bad = RemoteAuth(credential: { _ in .token(username: "pad", token: "nope") }, checkHostKey: { _ in .trusted })
        await #expect(throws: LFS.Failure.self) { try await repoB.lfsPull(remote: "origin", auth: bad) }
    }
}

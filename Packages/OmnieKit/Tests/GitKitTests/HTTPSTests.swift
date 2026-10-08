import Foundation
import Testing
@testable import GitKit

/// Token auth over smart HTTP against `git http-backend` behind a tiny Basic-auth server.
/// (Plain HTTP on localhost; the TLS layer is Apple's and isn't what's under test.)
@Suite(.serialized)
final class HTTPSTests {
    let root: URL
    let port = Int.random(in: 30000...60000)
    let server: Process
    let user = "pad"
    let token = "test-token-\(UUID().uuidString.prefix(8))"
    let me = Signature(name: "Pad", email: "pad@example.com")

    var url: String { "http://127.0.0.1:\(port)/forge.git" }

    static let serverScript = #"""
    import base64, os, subprocess, sys
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    ROOT, PORT, USER, TOKEN = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
    EXPECTED = "Basic " + base64.b64encode(f"{USER}:{TOKEN}".encode()).decode()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"  # closes each connection; keep-alive in this toy server stalled libgit2 for ~20 s
        def body(self):
            if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
                data = b""
                while True:
                    size = int(self.rfile.readline().strip(), 16)
                    if size == 0:
                        self.rfile.readline()
                        return data
                    data += self.rfile.read(size)
                    self.rfile.readline()
            n = int(self.headers.get("Content-Length") or 0)
            return self.rfile.read(n) if n else b""
        def serve(self, method):
            body = self.body()
            if self.headers.get("Authorization", "") != EXPECTED:
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Basic realm="forge"')
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            path, _, query = self.path.partition("?")
            env = dict(os.environ, GIT_PROJECT_ROOT=ROOT, GIT_HTTP_EXPORT_ALL="1", PATH_INFO=path,
                       QUERY_STRING=query, REQUEST_METHOD=method, REMOTE_USER=USER,
                       CONTENT_TYPE=self.headers.get("Content-Type", ""), CONTENT_LENGTH=str(len(body)))
            if self.headers.get("Content-Encoding"):
                env["HTTP_CONTENT_ENCODING"] = self.headers["Content-Encoding"]
            out = subprocess.run(["git", "http-backend"], input=body, env=env, capture_output=True).stdout
            sep = b"\r\n\r\n" if b"\r\n\r\n" in out else b"\n\n"
            head, _, payload = out.partition(sep)
            status, headers = 200, []
            for line in head.replace(b"\r\n", b"\n").split(b"\n"):
                key, _, value = line.decode().partition(":")
                if key.lower() == "status":
                    status = int(value.strip().split()[0])
                elif key:
                    headers.append((key, value.strip()))
            self.send_response(status)
            for key, value in headers:
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        def do_GET(self): self.serve("GET")
        def do_POST(self): self.serve("POST")
        def log_message(self, *args): pass

    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
    """#

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("https-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bare = root.appendingPathComponent("forge.git")
        try SSHTests.git(["init", "--quiet", "--bare", "-b", "main", bare.path], in: root)
        try SSHTests.git(["--git-dir", bare.path, "config", "http.receivepack", "true"], in: root)
        let seed = root.appendingPathComponent("seed")
        try SSHTests.git(["init", "--quiet", "-b", "main", seed.path], in: root)
        try "hello\n".write(to: seed.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try SSHTests.git(["add", "-A"], in: seed)
        try SSHTests.git(["commit", "--quiet", "-m", "Seed"], in: seed)
        try SSHTests.git(["push", "--quiet", bare.path, "main"], in: seed)

        let script = root.appendingPathComponent("server.py")
        try Self.serverScript.write(to: script, atomically: true, encoding: .utf8)
        server = Process()
        server.executableURL = URL(filePath: "/usr/bin/env")
        server.arguments = ["python3", script.path, root.path, String(port), user, token]
        server.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try server.run()
        try Self.waitForHTTP(port)
    }

    deinit {
        if server.isRunning {
            let pid = server.processIdentifier
            kill(pid, SIGTERM)
            for _ in 0..<100 where kill(pid, 0) == 0 {
                waitpid(pid, nil, WNOHANG)
                usleep(20_000)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    static func waitForHTTP(_ port: Int) throws {
        for _ in 0..<100 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            } == 0
            close(fd)
            if ok { return }
            usleep(50_000)
        }
        throw GitKitTests.CLIError(message: "HTTP server did not start")
    }

    func auth(token: String? = nil) -> RemoteAuth {
        let user = self.user, t = token ?? self.token
        return RemoteAuth(credential: { _ in .token(username: user, token: t) }, checkHostKey: { _ in .trusted })
    }

    @Test func cloneAndPushWithToken() async throws {
        let dest = root.appendingPathComponent("clone")
        let repo = try await Repository.clone(from: url, to: dest, auth: auth())
        #expect(try await repo.log().map(\.summary) == ["Seed"])

        try "hello\nfrom https\n".write(to: dest.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let c = try await repo.commitAll(message: "Over HTTPS\n", author: me)
        try await repo.pushCurrentBranch(auth: auth())
        let tip = try SSHTests.git(["--git-dir", root.appendingPathComponent("forge.git").path, "rev-parse", "main"], in: root)
        #expect(tip == c.id.hex)
    }

    @Test func wrongTokenFailsCleanly() async throws {
        await #expect(throws: GitKitError.authenticationFailed(url)) {
            _ = try await Repository.clone(from: url, to: root.appendingPathComponent("clone"), auth: auth(token: "wrong"))
        }
    }

    @Test func missingTokenSaysSo() async throws {
        let noToken = RemoteAuth(credential: { _ in nil }, checkHostKey: { _ in .trusted })
        await #expect(throws: GitKitError.noCredential(url)) {
            _ = try await Repository.clone(from: url, to: root.appendingPathComponent("clone"), auth: noToken)
        }
    }
}

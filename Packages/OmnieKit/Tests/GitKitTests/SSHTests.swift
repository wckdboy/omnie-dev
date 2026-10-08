import CryptoKit
import Foundation
import Testing
@testable import GitKit

/// End-to-end SSH against a throwaway OpenSSH server on localhost, authenticated through the
/// custom-sign callback (the same path the Secure Enclave key uses on device).
@Suite(.serialized)
final class SSHTests {
    let root: URL
    let port: Int
    let sshd: Process
    let signer = P256SSHSigner(softwareKey: P256.Signing.PrivateKey())
    let user = NSUserName()
    let hostKeyFingerprint: String

    var bareRepo: URL { root.appendingPathComponent("remote.git") }
    var sshURL: String { "ssh://\(user)@127.0.0.1:\(port)\(bareRepo.path(percentEncoded: false))" }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sshtest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        port = Int.random(in: 30000...60000)

        let hostKey = root.appendingPathComponent("host_ed25519").path
        try Self.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", hostKey])
        hostKeyFingerprint = try Self.run("/usr/bin/ssh-keygen", ["-l", "-E", "sha256", "-f", hostKey + ".pub"])
            .split(separator: " ")[1].description

        let authorized = root.appendingPathComponent("authorized_keys")
        try (signer.authorizedKeysLine(comment: "gitkit-test") + "\n").write(to: authorized, atomically: true, encoding: .utf8)

        let config = root.appendingPathComponent("sshd_config")
        try """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(hostKey)
        AuthorizedKeysFile \(authorized.path)
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        StrictModes no
        PidFile \(root.appendingPathComponent("sshd.pid").path)
        """.write(to: config, atomically: true, encoding: .utf8)

        sshd = Process()
        sshd.executableURL = URL(filePath: "/usr/sbin/sshd")
        sshd.arguments = ["-D", "-e", "-f", config.path]
        sshd.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try sshd.run()
        try Self.waitForPort(port)

        // The "forge": a bare repo with one commit, made with the git CLI.
        try Self.git(["init", "--quiet", "--bare", "-b", "main", bareRepo.path], in: root)
        let seed = root.appendingPathComponent("seed")
        try Self.git(["init", "--quiet", "-b", "main", seed.path], in: root)
        try "hello\n".write(to: seed.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try Self.git(["add", "-A"], in: seed)
        try Self.git(["commit", "--quiet", "-m", "Seed"], in: seed)
        try Self.git(["push", "--quiet", bareRepo.path, "main"], in: seed)
    }

    deinit {
        // Not Process.waitUntilExit(): Swift Testing releases suites on the main thread while the
        // main queue is being drained, and waitUntilExit needs that run loop, so it deadlocks.
        if sshd.isRunning {
            let pid = sshd.processIdentifier
            kill(pid, SIGTERM)
            for _ in 0..<100 where kill(pid, 0) == 0 {
                waitpid(pid, nil, WNOHANG)
                usleep(20_000)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    @discardableResult
    static func run(_ tool: String, _ args: [String], in dir: URL? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(filePath: tool)
        p.arguments = args
        if let dir { p.currentDirectoryURL = dir }
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw GitKitTests.CLIError(message: String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    static func git(_ args: [String], in dir: URL) throws -> String {
        try run("/usr/bin/git", ["-c", "user.name=CLI", "-c", "user.email=cli@example.com"] + args, in: dir)
    }

    static func waitForPort(_ port: Int) throws {
        for _ in 0..<60 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            } == 0
            // Ready means sshd sends its "SSH-2.0-…" banner, not just that the port accepts.
            var banner = [UInt8](repeating: 0, count: 4)
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let ready = connected && recv(fd, &banner, 4, MSG_WAITALL) == 4 && banner == Array("SSH-".utf8)
            close(fd)
            if ready { return }
            usleep(50_000)
        }
        throw GitKitTests.CLIError(message: "sshd did not start on port \(port)")
    }

    func auth(signer: (any SSHSigner)? = nil, hosts: KnownHosts) -> RemoteAuth {
        let s = signer ?? self.signer
        let user = self.user
        return RemoteAuth(credential: { _ in .sshSigner(username: user, signer: s) },
                          checkHostKey: { hosts.check($0) })
    }

    func trustedHosts() -> KnownHosts {
        let hosts = KnownHosts(fileURL: nil)
        try? hosts.trust(HostKey(host: "127.0.0.1", fingerprint: hostKeyFingerprint, keyType: "ssh-ed25519"))
        return hosts
    }

    // MARK: Tests

    @Test func signerProducesOpenSSHCompatibleKeyLine() throws {
        let line = signer.authorizedKeysLine(comment: "c")
        let file = root.appendingPathComponent("k.pub")
        try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
        let fp = try Self.run("/usr/bin/ssh-keygen", ["-l", "-E", "sha256", "-f", file.path]).split(separator: " ")[1]
        #expect(String(fp) == signer.fingerprint)
    }

    @Test func unknownHostKeyIsRefusedWithItsFingerprint() async throws {
        let dest = root.appendingPathComponent("clone")
        await #expect(throws: GitKitError.unknownHostKey(HostKey(host: "127.0.0.1", fingerprint: hostKeyFingerprint, keyType: "ssh-ed25519"))) {
            _ = try await Repository.clone(from: sshURL, to: dest, auth: auth(hosts: KnownHosts(fileURL: nil)))
        }
    }

    @Test func changedHostKeyIsRefused() async throws {
        let hosts = KnownHosts(fileURL: nil)
        try hosts.trust(HostKey(host: "127.0.0.1", fingerprint: "SHA256:somethingElse", keyType: nil))
        do {
            _ = try await Repository.clone(from: sshURL, to: root.appendingPathComponent("clone"), auth: auth(hosts: hosts))
            Issue.record("clone should have failed")
        } catch let GitKitError.hostKeyChanged(key, expected) {
            #expect(key.fingerprint == hostKeyFingerprint)
            #expect(expected == "SHA256:somethingElse")
        }
    }

    @Test func cloneOverSSHWithCustomSigner() async throws {
        let dest = root.appendingPathComponent("clone")
        let repo = try await Repository.clone(from: sshURL, to: dest, auth: auth(hosts: trustedHosts()))
        let log = try await repo.log()
        #expect(log.map(\.summary) == ["Seed"])
        #expect(try await repo.head().branch == "main")
        #expect(try String(contentsOf: dest.appendingPathComponent("README.md"), encoding: .utf8) == "hello\n")
        #expect(try await repo.remotes() == [RemoteInfo(name: "origin", url: sshURL)])
    }

    @Test func wrongKeyIsRejected() async throws {
        let stranger = P256SSHSigner(softwareKey: P256.Signing.PrivateKey())
        await #expect(throws: GitKitError.authenticationFailed(sshURL)) {
            _ = try await Repository.clone(from: sshURL, to: root.appendingPathComponent("clone"),
                                           auth: auth(signer: stranger, hosts: trustedHosts()))
        }
    }

    @Test func pushThenFetchMatchesCLI() async throws {
        let hosts = trustedHosts()
        let dest = root.appendingPathComponent("clone")
        let repo = try await Repository.clone(from: sshURL, to: dest, auth: auth(hosts: hosts))

        try "hello\nfrom the iPad\n".write(to: dest.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let c = try await repo.commitAll(message: "Edit on iPad\n", author: Signature(name: "Pad", email: "pad@example.com"))
        #expect(try await repo.status().ahead == 1)

        try await repo.pushCurrentBranch(auth: auth(hosts: hosts))
        #expect(try Self.git(["--git-dir", bareRepo.path, "rev-parse", "main"], in: root) == c.id.hex)

        // Someone else pushes; fetch shows we're behind.
        let other = root.appendingPathComponent("other")
        try Self.git(["clone", "--quiet", bareRepo.path, other.path], in: root)
        try "x\n".write(to: other.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        try Self.git(["add", "-A"], in: other)
        try Self.git(["commit", "--quiet", "-m", "From the Mac"], in: other)
        try Self.git(["push", "--quiet", "origin", "main"], in: other)

        try await repo.fetch(auth: auth(hosts: hosts))
        let status = try await repo.status()
        #expect(status.ahead == 0)
        #expect(status.behind == 1)
    }

    @Test func nonFastForwardPushIsRejected() async throws {
        let hosts = trustedHosts()
        let dest = root.appendingPathComponent("clone")
        let repo = try await Repository.clone(from: sshURL, to: dest, auth: auth(hosts: hosts))

        // Remote moves on.
        let other = root.appendingPathComponent("other")
        try Self.git(["clone", "--quiet", bareRepo.path, other.path], in: root)
        try "y\n".write(to: other.appendingPathComponent("y.txt"), atomically: true, encoding: .utf8)
        try Self.git(["add", "-A"], in: other)
        try Self.git(["commit", "--quiet", "-m", "Remote change"], in: other)
        try Self.git(["push", "--quiet", "origin", "main"], in: other)

        try "z\n".write(to: dest.appendingPathComponent("z.txt"), atomically: true, encoding: .utf8)
        try await repo.commitAll(message: "Local change\n", author: Signature(name: "Pad", email: "pad@example.com"))
        do {
            try await repo.pushCurrentBranch(auth: auth(hosts: hosts))
            Issue.record("push should have been rejected")
        } catch GitKitError.pushRejected(let ref, _) {
            #expect(ref == "refs/heads/main")
        }
        #expect(try Self.git(["--git-dir", bareRepo.path, "log", "-1", "--format=%s", "main"], in: root) == "Remote change")
    }
}

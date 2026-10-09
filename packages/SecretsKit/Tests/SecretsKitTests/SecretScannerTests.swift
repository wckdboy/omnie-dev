// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Testing
@testable import SecretsKit

/// Fake tokens are assembled at runtime so this file doesn't trip forges' push protection.
struct SecretScannerTests {
    let scanner = SecretScanner()
    let body = String(repeating: "a1B2c3D4e5", count: 4)

    func rules(_ text: String) -> [String] {
        scanner.scan(path: "f", line: 1, text: text).map(\.rule)
    }

    @Test func knownFormats() {
        #expect(rules("token = \"" + "gh" + "p_" + body + "\"") == ["GitHub token"])
        #expect(rules("github" + "_pat_" + body) == ["GitHub token"])
        #expect(rules("AK" + "IA" + "IOSFODNN7EXAMPLE") == ["AWS access key"])
        #expect(rules("glpat" + "-" + body) == ["GitLab token"])
        #expect(rules("ANTHROPIC_API_KEY=" + "sk-" + "ant-" + body) == ["Anthropic API key"])
        #expect(rules("OPENAI=" + "sk-" + "proj-" + body) == ["OpenAI API key"])
        #expect(rules("xo" + "xb-" + "1234567890-abcdef") == ["Slack token"])
        #expect(rules("sk" + "_live_" + body) == ["Stripe live key"])
        #expect(rules("AI" + "za" + String(body.prefix(35))) == ["Google API key"])
        #expect(rules("-----BEGIN " + "OPENSSH PRIVATE KEY-----") == ["Private key"])
    }

    @Test func oneFindingPerSecret() {
        // A known token inside a password assignment is reported once, by its specific rule.
        #expect(rules("password: \"" + "gh" + "p_" + body + "\"") == ["GitHub token"])
    }

    @Test func genericAssignmentNeedsARandomValue() {
        #expect(rules("password = \"Zq8#vL2!pR7@kW4m\"") == ["Possible secret"])
        #expect(rules("password = \"changeme-changeme\"").isEmpty)
        #expect(rules("api_key: \"${API_KEY_FROM_ENV}\"").isEmpty)
        #expect(rules("secret = \"aaaaaaaaaaaaaaaa\"").isEmpty)
        #expect(rules("let password = readPassword()").isEmpty)
    }

    @Test func ordinaryCodeIsQuiet() {
        for line in ["import Foundation", "const skipList = ['sk-', 'ghp_']", "let task = \"ask-anything\"",
                     "url = \"https://example.com/AKIA\"", "// password must be 12+ characters"] {
            #expect(rules(line).isEmpty, "\(line)")
        }
    }

    @Test func allowMarkerSkipsTheLine() {
        #expect(rules("gh" + "p_" + body + " // omnie:allow-secret").isEmpty)
    }

    @Test func redactionHidesTheSecret() throws {
        let token = "gh" + "p_" + body
        let finding = try #require(scanner.scan(path: "a.env", line: 3, text: "T=\(token)").first)
        #expect(!finding.redacted.contains(String(body.suffix(20))))
        #expect(finding.redacted.hasPrefix("ghp_"))
        #expect(finding.path == "a.env" && finding.line == 3 && finding.isCertain)
    }
}

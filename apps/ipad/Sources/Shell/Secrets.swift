// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import GitKit
import SecretsKit

/// The audit log's HMAC key: 32 random bytes in the Keychain, made once. With it the log is
/// tamper-evident even if the file is replaced. If the Keychain is unavailable the log falls back
/// to a plain hash chain — never to a key that could change under it.
enum AuditKey {
    private static let account = "audit.hmac-key"
    static let current: SymmetricKey? = {
        if let data = Keychain.data(for: account), data.count == 32 { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        do { try Keychain.set(data, for: account); return key } catch { return nil }
    }()
}

extension SSHIdentity {
    /// The identity as GitKit's SSH signer. Secure Enclave keys sign inside the Enclave.
    var signer: P256SSHSigner {
        switch key {
        case .secureEnclave(let k): P256SSHSigner(secureEnclaveKey: k)
        case .software(let k): P256SSHSigner(softwareKey: k)
        }
    }
}

enum AppPaths {
    static var support: URL {
        let url = URL.applicationSupportDirectory.appendingPathComponent("Omnie-dev", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Cloned projects live in Documents so they show up in the Files app.
    static var projects: URL {
        let url = URL.documentsDirectory.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

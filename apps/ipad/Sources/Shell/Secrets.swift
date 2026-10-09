// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import GitKit
import SecretsKit

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

// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Security

/// The device's SSH identity. On hardware it's a Secure Enclave key: the private key can't be
/// exported or read, only asked to sign. Without a Secure Enclave (the simulator) it falls back
/// to a software key in the Keychain and says so.
public struct SSHIdentity {
    public enum Key {
        case secureEnclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)
    }

    public let key: Key

    public var isHardwareBacked: Bool {
        if case .secureEnclave = key { return true }
        return false
    }

    public var publicKey: P256.Signing.PublicKey {
        switch key {
        case .secureEnclave(let k): k.publicKey
        case .software(let k): k.publicKey
        }
    }

    private static let account = "ssh.identity.p256"
    private static let kindAccount = "ssh.identity.kind"

    public static func load() -> SSHIdentity? {
        guard let data = Keychain.data(for: account),
              let kind = Keychain.data(for: kindAccount).map({ String(decoding: $0, as: UTF8.self) }) else { return nil }
        if kind == "secure-enclave", let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data) {
            return SSHIdentity(key: .secureEnclave(key))
        }
        if kind == "software", let key = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            return SSHIdentity(key: .software(key))
        }
        return nil
    }

    public static func create() throws -> SSHIdentity {
        if SecureEnclave.isAvailable {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                               .privateKeyUsage, &error) else {
                throw error!.takeRetainedValue() as Error
            }
            let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
            // dataRepresentation is an opaque handle only this device's Secure Enclave can use.
            try Keychain.set(key.dataRepresentation, for: account)
            try Keychain.set(Data("secure-enclave".utf8), for: kindAccount)
            return SSHIdentity(key: .secureEnclave(key))
        }
        let key = P256.Signing.PrivateKey()
        try Keychain.set(key.rawRepresentation, for: account)
        try Keychain.set(Data("software".utf8), for: kindAccount)
        return SSHIdentity(key: .software(key))
    }

    public static func delete() {
        Keychain.delete(account)
        Keychain.delete(kindAccount)
    }
}

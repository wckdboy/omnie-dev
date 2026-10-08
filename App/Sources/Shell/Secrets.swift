import CryptoKit
import Foundation
import GitKit
import LocalAuthentication
import Security

/// Minimal SecretsKit until it becomes its own package (PLAN.md §12): Keychain items are
/// this-device-only and never synced to iCloud.
enum Keychain {
    static let service = "ai.wckd.omniedev"

    static func data(for account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func set(_ data: Data, for account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func delete(_ account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}

/// The device's SSH identity. On hardware it's a Secure Enclave key: the private key can't be
/// exported or read, only asked to sign. The simulator has no Secure Enclave, so it falls back
/// to a software key in the Keychain and says so.
struct SSHIdentity {
    let signer: P256SSHSigner
    let isHardwareBacked: Bool

    private static let account = "ssh.identity.p256"
    private static let kindAccount = "ssh.identity.kind"

    static func load() -> SSHIdentity? {
        guard let data = Keychain.data(for: account),
              let kind = Keychain.data(for: kindAccount).map({ String(decoding: $0, as: UTF8.self) }) else { return nil }
        if kind == "secure-enclave", let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data) {
            return SSHIdentity(signer: P256SSHSigner(secureEnclaveKey: key), isHardwareBacked: true)
        }
        if kind == "software", let key = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            return SSHIdentity(signer: P256SSHSigner(softwareKey: key), isHardwareBacked: false)
        }
        return nil
    }

    static func create() throws -> SSHIdentity {
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
            return SSHIdentity(signer: P256SSHSigner(secureEnclaveKey: key), isHardwareBacked: true)
        }
        let key = P256.Signing.PrivateKey()
        try Keychain.set(key.rawRepresentation, for: account)
        try Keychain.set(Data("software".utf8), for: kindAccount)
        return SSHIdentity(signer: P256SSHSigner(softwareKey: key), isHardwareBacked: false)
    }

    static func delete() {
        Keychain.delete(account)
        Keychain.delete(kindAccount)
    }
}

enum HumanCheck {
    /// Face ID (or passcode) before an outward action like push. One check covers a whole Sync.
    /// Devices with no passcode can't authenticate anyone, so the check passes there.
    static func confirm(_ reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return (error as? LAError)?.code == .passcodeNotSet
        }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
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

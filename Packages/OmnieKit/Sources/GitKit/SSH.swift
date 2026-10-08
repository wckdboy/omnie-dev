import CGitSSH
import CryptoKit
import Foundation

/// Signs SSH public-key authentication without handing a private key to libgit2 or libssh2.
/// The Secure Enclave signer is the default on device; the private key never exists in memory.
public protocol SSHSigner: Sendable {
    /// SSH key type, e.g. "ecdsa-sha2-nistp256".
    var keyType: String { get }
    /// The public key in SSH wire format.
    var publicKeyBlob: Data { get }
    /// Signs `data` and returns the SSH signature blob (without the algorithm name).
    func signatureBlob(for data: Data) throws -> Data
}

public extension SSHSigner {
    /// The line to paste into a forge's SSH keys page or authorized_keys.
    func authorizedKeysLine(comment: String = "") -> String {
        let line = "\(keyType) \(publicKeyBlob.base64EncodedString())"
        return comment.isEmpty ? line : "\(line) \(comment)"
    }

    /// OpenSSH-style fingerprint, "SHA256:…".
    var fingerprint: String { SSHWire.fingerprint(of: publicKeyBlob) }
}

/// ECDSA P-256 (`ecdsa-sha2-nistp256`), backed by the Secure Enclave or by a software key.
public struct P256SSHSigner: SSHSigner {
    public let keyType = "ecdsa-sha2-nistp256"
    public let publicKeyBlob: Data
    private let sign: @Sendable (Data) throws -> Data

    /// Software key, for tests and for platforms without a Secure Enclave.
    public init(softwareKey key: P256.Signing.PrivateKey) {
        publicKeyBlob = Self.blob(for: key.publicKey)
        sign = { try key.signature(for: $0).rawRepresentation }
    }

    /// Secure Enclave key. Signing may show the system Face ID prompt if the key requires it.
    public init(secureEnclaveKey key: SecureEnclave.P256.Signing.PrivateKey) {
        publicKeyBlob = Self.blob(for: key.publicKey)
        let box = UncheckedBox(key)
        sign = { try box.value.signature(for: $0).rawRepresentation }
    }

    public func signatureBlob(for data: Data) throws -> Data {
        // CryptoKit hashes with SHA-256, which is what ecdsa-sha2-nistp256 specifies (RFC 5656).
        let raw = try sign(data)
        guard raw.count == 64 else { throw GitKitError.signingFailed("unexpected signature length \(raw.count)") }
        return SSHWire.mpint(raw.prefix(32)) + SSHWire.mpint(raw.suffix(32))
    }

    static func blob(for key: P256.Signing.PublicKey) -> Data {
        SSHWire.string("ecdsa-sha2-nistp256") + SSHWire.string("nistp256") + SSHWire.string(key.x963Representation)
    }
}

/// SecureEnclave keys aren't marked Sendable; they are immutable handles, safe to share.
private final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// SSH wire encoding (RFC 4251 §5).
enum SSHWire {
    static func uint32(_ v: Int) -> Data {
        withUnsafeBytes(of: UInt32(v).bigEndian) { Data($0) }
    }

    static func string(_ bytes: Data) -> Data { uint32(bytes.count) + bytes }
    static func string(_ text: String) -> Data { string(Data(text.utf8)) }

    /// Unsigned big-endian integer as an SSH mpint: no leading zeros, plus one zero byte if the high bit is set.
    static func mpint(_ bytes: some Collection<UInt8>) -> Data {
        var trimmed = Data(bytes.drop { $0 == 0 })
        if let first = trimmed.first, first & 0x80 != 0 { trimmed.insert(0, at: 0) }
        return string(trimmed)
    }

    static func fingerprint(of blob: Data) -> String {
        let digest = Data(SHA256.hash(data: blob))
        return "SHA256:" + digest.base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

/// Holds a signer for the duration of a network operation; passed to C as the credential payload.
final class SignerBox: @unchecked Sendable {
    let signer: any SSHSigner
    var lastError: Error?
    init(_ signer: any SSHSigner) { self.signer = signer }
}

/// The C function libssh2 ends up calling (through CGitSSH's trampoline) to sign an auth request.
let sshSignFunction: omnie_ssh_sign_fn = { data, dataLen, sig, sigLen, payload in
    guard let data, let sig, let sigLen, let payload else { return -1 }
    let box = Unmanaged<SignerBox>.fromOpaque(payload).takeUnretainedValue()
    do {
        let blob = try box.signer.signatureBlob(for: Data(bytes: data, count: dataLen))
        guard let buffer = malloc(blob.count)?.assumingMemoryBound(to: UInt8.self) else { return -1 }
        blob.copyBytes(to: buffer, count: blob.count)
        sig.pointee = buffer
        sigLen.pointee = blob.count
        return 0
    } catch {
        box.lastError = error
        return -1
    }
}

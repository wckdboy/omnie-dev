# P0 spike 5: git over SSH with a Secure Enclave key (PLAN §9, Appendix A)

**Status (9 Oct 2026): verified against GitHub on the device.** A non-exportable Secure Enclave P-256 key created on the iPad Pro 13" M5 (iPadOS 27.0) authenticates a libgit2 clone over SSH from github.com.

## Path

libgit2 1.9.7 → libssh2 1.11.1 (OpenSSL 3.6.5 libcrypto) → the `CGitSSH` sign callback → `SecKeyCreateSignature` on the Secure Enclave key (`ecdsa-sha2-nistp256`). The private key never leaves the Enclave; the app gives libssh2 a signature, not a key.

## Results

| Check | Result |
|---|---|
| Sign callback against OpenSSH (macOS tests, simulator with a software P-256 key) | ✅ clone, fetch and push (8 Oct 2026) |
| Secure Enclave key generated on the device, public key exported in OpenSSH format | ✅ `SHA256:9FVOYMIjh32TpPVghJPrkP+nVhPQmOAbV0AAaOzavsI` |
| GitHub accepts an `ecdsa-sha2-nistp256` authentication key | ✅ added as "Omnie-dev DOOMpad (Secure Enclave)" |
| Host key check | ✅ `known_hosts` pinned to github.com's ECDSA key, `SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM` |
| Clone `git@github.com:wckdboy/omnie-dev.git` on the device (debug build, `-OmnieClone`) | ✅ full working tree and `.git` in `Documents/Projects/omnie-dev` |

GitHub requires public-key authentication for every SSH connection, public repos included, and the app holds no other key, so the clone proves the Enclave signature was accepted.

## Still open

- **Push from the device** uses the same authentication and was verified in the simulator; it wasn't repeated against GitHub to avoid writing a test ref to the real repo.
- **Other forges:** GitLab, Codeberg/Forgejo and Cursor Origin are expected to accept `ecdsa-sha2-nistp256` (GitLab and Forgejo document ECDSA keys) but weren't tested.

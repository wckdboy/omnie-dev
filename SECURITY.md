# Security

Please report vulnerabilities privately through GitHub's **Report a vulnerability** button on the Security tab of this repository. Don't open a public issue.

This is one person's project, so handling is best effort with no SLA: fix first, then publish an advisory (with a CVE when it matters).

These areas jump the queue:

- the policy engine and approval tiers (PolicyKit)
- secrets handling: SSH keys, HTTPS tokens, the Keychain and Secure Enclave code
- the bridge between native code and web views or sandboxes
- LinuxKit's syscall policy, once it exists

Issues in upstream dependencies (libgit2, libssh2, OpenSSL, iSH) are also reported upstream.

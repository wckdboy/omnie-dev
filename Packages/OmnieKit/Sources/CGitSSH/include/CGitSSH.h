#pragma once
#include <stddef.h>
#include <stdint.h>

struct git_credential;

/// Signs `data` for SSH public-key auth. On success writes a malloc'd signature blob
/// (for ECDSA: mpint r || mpint s) to `*sig` and returns 0; libssh2 frees it with free().
typedef int (*omnie_ssh_sign_fn)(const uint8_t *data, size_t data_len,
                                 uint8_t **sig, size_t *sig_len, void *payload);

/// Installs the process-wide signing function used by every custom SSH credential.
void omnie_ssh_set_sign_function(omnie_ssh_sign_fn fn);

/// git_credential_ssh_custom_new with a C trampoline as the libssh2 sign callback.
/// `public_key_blob` is the SSH wire-format public key; `payload` is passed to the sign function.
int omnie_credential_ssh_custom_new(struct git_credential **out, const char *username,
                                    const uint8_t *public_key_blob, size_t blob_len,
                                    void *payload);

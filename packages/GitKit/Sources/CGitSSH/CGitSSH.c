// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

#include "CGitSSH.h"
#include <stdatomic.h>

// libgit2's public header declares the sign callback as variadic unless libssh2's headers are
// included, which Swift can't implement. This file supplies a callback with libssh2's real
// signature and forwards to a plain C function that Swift provides.

typedef struct _LIBSSH2_SESSION LIBSSH2_SESSION;
typedef int (*libssh2_sign_cb)(LIBSSH2_SESSION *session, unsigned char **sig, size_t *sig_len,
                               const unsigned char *data, size_t data_len, void **abstract);

extern int git_credential_ssh_custom_new(struct git_credential **out, const char *username,
                                         const char *publickey, size_t publickey_len,
                                         libssh2_sign_cb sign_callback, void *payload);

static _Atomic(omnie_ssh_sign_fn) sign_function = NULL;

void omnie_ssh_set_sign_function(omnie_ssh_sign_fn fn) {
    atomic_store(&sign_function, fn);
}

static int trampoline(LIBSSH2_SESSION *session, unsigned char **sig, size_t *sig_len,
                      const unsigned char *data, size_t data_len, void **abstract) {
    (void)session;
    omnie_ssh_sign_fn fn = atomic_load(&sign_function);
    if (fn == NULL || abstract == NULL) return -1;
    // libgit2 passes &credential->payload as the libssh2 "abstract" pointer.
    return fn(data, data_len, sig, sig_len, *abstract);
}

int omnie_credential_ssh_custom_new(struct git_credential **out, const char *username,
                                    const uint8_t *public_key_blob, size_t blob_len,
                                    void *payload) {
    return git_credential_ssh_custom_new(out, username, (const char *)public_key_blob, blob_len,
                                         trampoline, payload);
}

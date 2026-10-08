# Contributing to Omnie-dev

Omnie-dev is a personal tool, built for its author's daily use and shared openly. The roadmap follows that use, but issues, fixes and ideas are welcome.

## License and sign-off

- Contributions are **Apache-2.0 in, Apache-2.0 out**. There is no CLA.
- Every commit needs a [Developer Certificate of Origin](https://developercertificate.org) sign-off. Use `git commit -s`, which adds:

  ```
  Signed-off-by: Your Name <you@example.com>
  ```

- **AI-assisted commits** also carry an `Assisted-by:` trailer naming the model, for example `Assisted-by: claude-opus-5-5`. Omnie-dev uses the same trailer to color agent-written lines in its own UI.
- New source files start with an SPDX header:

  ```swift
  // SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
  // SPDX-License-Identifier: Apache-2.0
  ```

  The repo follows the [REUSE](https://reuse.software) spec; `reuse lint` should pass.

## Before opening a pull request

```sh
scripts/build-git-deps.sh      # once
for k in packages/*; do (cd "$k" && swift test); done
xcodegen generate && xcodebuild -scheme OmnieDev -destination 'generic/platform=iOS Simulator' build
```

GitKit tests are differential against the `git` CLI and start throwaway localhost `sshd` and HTTP servers; they need macOS with `/usr/sbin/sshd` and `python3`.

## Where things go

The app and every `*Kit` live in this monorepo. A new repository needs one of five reasons (different license, upstream fork, reuse without the app, different release cadence, different toolchain) written in its README. See PLAN §27.3.

Policy-sensitive paths (PolicyKit, SecretsKit, the SSH/HTTPS credential code, license files, `vendor/`) need an explicit review from a code owner.

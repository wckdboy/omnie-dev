# Omnie-dev

A native, offline-first IDE for agent-assisted coding. On iPad it's the full IDE; on iPhone it's an agent-first vibecoding app. See [docs/PLAN.md](docs/PLAN.md).

Bundle ID: `ai.wckd.omniedev` · iPadOS / iOS 26+

## Layout

Follows PLAN §27.3: one monorepo for the app and every Kit.

| Path | What |
|---|---|
| `apps/ipad` | The app target (universal: the IDE on iPad, the vibecoding shell on iPhone). `IDE/`, `Vibe/`, shared `Shell/` |
| `packages/DesignKit` | Theme, density, metrics. Colors are generated from `brand/tokens.json` |
| `packages/CommandKit` | The command registry behind the palette, menu bar and shortcuts |
| `packages/WorkspaceKit` | File tree, text files |
| `packages/GitKit` | libgit2: checkpoints, timeline, commits, SSH (Secure Enclave signing) and HTTPS remotes, Sync, push queue, branches, agent task worktrees, conflicts, undo. `CGitSSH` is the C shim for the SSH signing callback |
| `brand/` | Design tokens (and, later, icon sources) |
| `scripts/` | `build-git-deps.sh` (native deps), `gen-theme.swift` |
| `docs/PLAN.md` | Architecture and plan |
| `project.yml` | XcodeGen spec. The `.xcodeproj` is generated and not committed |

## Build

```sh
brew install xcodegen cmake ninja   # once
scripts/build-git-deps.sh      # once (~2 min): OpenSSL libcrypto + libssh2 + libgit2 -> packages/GitKit/Vendor/
xcodegen generate              # after adding files or editing project.yml
open OmnieDev.xcodeproj

swift scripts/gen-theme.swift  # after editing brand/tokens.json
for k in packages/*; do (cd "$k" && swift test); done
```

Debug builds accept `-OmnieOpenFolder /path` to open a folder at launch and `-OmnieRunCommand <command id>` (repeatable) to run commands, which is handy in the simulator.

GitKit tests are differential: each operation is checked against the `git` CLI on the same repo.

## License

Omnie-dev's code is [Apache-2.0](LICENSE). Native dependencies keep their own licenses (see [NOTICE](NOTICE)). The name and icon aren't covered by the code license: see [TRADEMARKS.md](TRADEMARKS.md). Contributions use a DCO sign-off: see [CONTRIBUTING.md](CONTRIBUTING.md).

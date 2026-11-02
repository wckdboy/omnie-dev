# Omnie

[omnie.sh](https://omnie.sh) · [omnie.dk](https://omnie.dk) · [WCKD](https://wckd.ai)

**Omnie is becoming an integration hub for professional tools:** one place that connects the tools a
business already uses, so their data can work together. The first integration is e-conomic: project
and account data pulled read-only through the Omnie Connect app and used to build reports in Omnie.
Further integrations follow one at a time. It is in development; nothing here is a released product.

This repository is moving to that direction. What it holds today is the earlier Omnie Dev code, a
native, offline-first iPad/iPhone IDE for agent-assisted coding. That IDE is no longer developed as
Omnie. Its code, docs and CI stay here for reference until the hub replaces them.

## The earlier IDE (reference)

See [docs/PLAN.md](docs/PLAN.md) for its architecture and [docs/POSITIONING.md](docs/POSITIONING.md)
for its former positioning.

Bundle ID: `ai.wckd.omniedev` · iPadOS / iOS 26+

### Layout

Follows PLAN §27.3: one monorepo for the app and every Kit.

| Path | What |
|---|---|
| `apps/ipad` | The app target (universal: the IDE on iPad, the vibecoding shell on iPhone). `IDE/`, `Vibe/`, shared `Shell/` |
| `packages/DesignKit` | Theme, density, metrics. Colors are generated from `brand/tokens.json` |
| `packages/CommandKit` | The command registry behind the palette, menu bar and shortcuts |
| `packages/WorkspaceKit` | File tree, text files |
| `packages/LangKit` | Language detection, tree-sitter grammars and highlight queries (grammars vendored by `scripts/vendor-grammars.py`) |
| `packages/EditorKit` | The code editor: `EditorView` protocol, the Core Text engine (`omnie-dev-editor-engine`, a Runestone fork) and the brand syntax theme |
| `packages/GitKit` | libgit2: checkpoints, timeline, commits, SSH (Secure Enclave signing) and HTTPS remotes, Sync, push queue, branches, agent task worktrees, conflicts, undo. `CGitSSH` is the C shim for the SSH signing callback |
| `brand/` | Design tokens (and, later, icon sources) |
| `scripts/` | `build-git-deps.sh` (native deps), `gen-theme.swift` |
| `docs/PLAN.md` | Architecture and plan |
| `docs/ROADMAP.md` | The milestone plan; `docs/STATUS.md` is what's built and measured |
| `CHANGELOG.md` | What shipped in each release |
| `project.yml` | XcodeGen spec. The `.xcodeproj` is generated and not committed |

### Build

```sh
brew install xcodegen cmake ninja   # once
scripts/build-git-deps.sh      # once (~2 min): OpenSSL libcrypto + libssh2 + libgit2 -> packages/GitKit/Vendor/
python3 scripts/vendor-grammars.py   # once: tree-sitter grammars -> packages/LangKit
xcodegen generate              # after adding files or editing project.yml
open OmnieDev.xcodeproj

swift scripts/gen-theme.swift  # after editing brand/tokens.json
for k in packages/*; do (cd "$k" && swift test); done
```

Debug builds accept `-OmnieOpenFolder /path` to open a folder at launch and `-OmnieRunCommand <command id>` (repeatable) to run commands, which is handy in the simulator.

If a long-lived checkout fills the disk, `scripts/clean.sh` removes the derived data (the monorepo's `.build`, each package's, and Xcode's).

GitKit tests are differential: each operation is checked against the `git` CLI on the same repo.

## License

Omnie-dev's code is [Apache-2.0](LICENSE). Native dependencies keep their own licenses (see [NOTICE](NOTICE)). The name and icon aren't covered by the code license: see [TRADEMARKS.md](TRADEMARKS.md). Contributions use a DCO sign-off: see [CONTRIBUTING.md](CONTRIBUTING.md).

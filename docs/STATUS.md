# Omnie Dev: status

What's built, measured and open, by roadmap phase (PLAN.md §22). Updated 9 Oct 2026. Device numbers are from an iPad Pro 13" M5 (12 GB, iPadOS 27).

## P0 spikes

| Spike | Result | Write-up |
|---|---|---|
| 1. Editor engine (Runestone fork) | Every automated test passes on the device. **Waiting on your hands-on tests 5–8** (IME, Scribble, hardware keyboard, VoiceOver) | `spikes/editor-p0.md` |
| 2. 7B on the device (MLX) | 26–30 tok/s decode, 650–790 tok/s prefill, 5.4 GB peak | `spikes/model-p0.md` |
| 3. WASI in WKWebView | 55/73 of the WASI test suite (every failure is the JS shim's); timeouts work | `spikes/wasi-p0.md` |
| 4. WebGPU and WebGL2 in our web view | Both work (WebGPU needs a secure context; a custom scheme counts) | `spikes/webgpu-p0.md` |
| 5. Secure Enclave SSH key | Clones from GitHub on the device | `spikes/git-ssh-p0.md` |
| 6. TestFlight build that runs user code | Build 0.1.0 (1) uploaded; **your check on the device is open** | — |

## P1 foundation: built

Shell, command palette and menus; editor with tree-sitter highlighting, marks, multi-cursor and VoiceOver; theme from the brand tokens and density modes; GitKit (clone over SSH or HTTPS, checkpoints, commit composer with secret scan, timeline, Sync, offline push queue, branches, conflicts, Undo); WorkspaceKit (recent projects, reopen at launch, live file watching); SecretsKit (Keychain, Secure Enclave SSH key, tokens, secret scanner); PolicyKit (approval tiers, tighten-only project rules, capability tokens, hash-chained audit log); Settings; plane mode; Acknowledgements.

Editor navigation: tabs (preview tabs, overflow past 8, ⌃Tab), quick open (⌘P), find in project (⇧⌘F), go to line (⌘L), go to symbol (⇧⌘O and `@` in the palette; `?` sends a task to the agent), and file operations in the navigator (new, rename, duplicate, delete after a checkpoint).

Open from the P1 bar: your hands-on editor checks; cloning from forges other than GitHub (GitLab, Forgejo, Origin) isn't tested.

## P2 plane-ready agent: mostly built

- **Models (ModelKit):** pinned, checksum-verified downloads (Tiny 0.5B, Standard 7B). Tiny drafts commit messages (0.19 s) and ghost text (~0.45 s after you stop typing).
- **Agent (AgentKit):** typed tools, policy on every call, journal and resume, a task branch and worktree per task, changeset review hunk by hunk, squash merge with an `Assisted-by` trailer. Agent pane on iPad, Agent and Changes tabs on iPhone.
- **Online models (start of P4):** Anthropic or any OpenAI-compatible API for agent tasks (Settings › Models), keys in the Keychain, consent per project with Face ID, routing Local / Online / Auto with plane mode forcing local. On the golden set, Claude Sonnet 5.5 passes **25/25** (~35 s a task) where the local 7B passes 18/25.
- **Quality:** golden task set, 25 tasks, run on the device with `-OmnieAgentEval`: **18/25 (72%)**, about 40 s a task, plateaued for the 4-bit 7B; what's left is the model's judgment. See `spikes/agent-p2.md`.
- **Security:** red-team corpus v1 (7 attack cases, real PolicyKit, approvals denied); it found and closed a symlink escape.

Open: an agreed pass rate on a larger task set; API models (P4) for tasks the local 7B can't do.

## P3 sandbox and tools: well underway

- **RunKit:** JavaScript/TypeScript (Sucrase in JavaScriptCore, ES modules in WKWebView) and Python (Pyodide) run on the device with no network and a timeout; vitest- and pytest-compatible subsets run a project's own tests. The agent has `run_tests` and `run_script`.
- **Terminal tab (TermKit):** built-in commands over the project (ls, cd, cat, grep, run, test, git status/log/diff, open), Run tests and Run file.
- **Preview:** a project's index.html live, TypeScript transpiled on the fly, reload on save, console with an error count.
- **Offline package cache, first tier:** three.js bundled and import-mapped, so `import * as THREE from "three"` works offline in previews, runs and tests.
- **Offline package cache, npm tier:** `npm install [name[@range]]` in the terminal (or Prepare for offline, per project) fetches packages and their dependencies from the registry, checks each against its integrity hash and unpacks it into Application Support. Previews, runs and tests then import them from the project's package.json with no connection: ES modules as they are, CommonJS wrapped as ES modules with named exports found statically. Checked with React 18 (server render), zod, date-fns, nanoid and lodash-es.
- **Stage:** glTF/GLB, OBJ and STL from the project in three.js, with a native performance HUD. On the iPad: 60 fps (WKWebView caps animation frames at 60 Hz). Python starts and runs in under a second. See `spikes/runkit-p3.md`.
- **Tools tab (ToolsKit):** HTTP client (`.http` files, secrets from the Keychain), API mock server (recorded responses, and routes generated from an OpenAPI or Swagger spec, JSON or YAML, in the project, served to previews), SQLite browser (read-only by default) and the Patterns lab (JSON, regex in JS and Swift flavors).
- **Markdown + Mermaid preview** in the Preview tab for the open `.md` file.
- **Type checking:** TypeScript 5.9 runs offline over the whole project (tsconfig.json honoured, with the declarations of packages in the offline cache) when it opens and after saves: underlines in the editor, an error count in the status strip, a Problems list (⇧⌘M). The agent has `check_types` in TypeScript projects.

Open: WASI tools in RunKit, PyPI packages beyond Pyodide's, the Stage inspector and shader hot reload, offline docs.

## How to check things yourself

- Debug launch arguments (debug builds): `-OmnieOpenFolder <path in Documents>`, `-OmnieRunTests`, `-OmniePreview`, `-OmnieAgentDemo`, `-OmnieAgentTask "<goal>"`, `-OmnieAgentEval <label>`, `-OmnieModelSmoke`.
- Packages: `swift test` in each `packages/*` (EditorKit runs on the simulator: `xcodebuild test -scheme EditorKit`).
- Vendored inputs (gitignored): `scripts/build-git-deps.sh`, `scripts/vendor-grammars.py`, `scripts/vendor-runkit.sh`, `scripts/vendor-wasi-spike.py`.

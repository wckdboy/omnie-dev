# Omnie Dev: status

What's built, measured and open, by roadmap phase (PLAN.md §22). Updated 9 Oct 2026. Device numbers are from an iPad Pro 13" M5 (12 GB, iPadOS 27).

## P0 spikes

| Spike | Result | Write-up |
|---|---|---|
| 1. Editor engine (Runestone fork) | Every automated test passes on the device. Hardware keyboard (7) and the machine-checkable half of VoiceOver (8) now run as UI tests and pass; **still by hand: IME candidates and dictation (5), Scribble (6), the VoiceOver rotor (8)** | `spikes/editor-p0.md` |
| 2. 7B on the device (MLX) | 26–30 tok/s decode, 650–790 tok/s prefill, 5.4 GB peak | `spikes/model-p0.md` |
| 3. WASI in WKWebView | 55/73 of the WASI test suite (every failure is the JS shim's); timeouts work | `spikes/wasi-p0.md` |
| 4. WebGPU and WebGL2 in our web view | Both work (WebGPU needs a secure context; a custom scheme counts) | `spikes/webgpu-p0.md` |
| 5. Secure Enclave SSH key | Clones from GitHub on the device | `spikes/git-ssh-p0.md` |
| 6. TestFlight build that runs user code | Build 0.1.0 (1) uploaded; **your check on the device is open** | — |

## P1 foundation: built

Shell, command palette and menus; editor with tree-sitter highlighting, marks, multi-cursor and VoiceOver; theme from the brand tokens and density modes; GitKit (clone over SSH or HTTPS, checkpoints, commit composer with secret scan, timeline, Sync, offline push queue, branches, conflicts with agent proposals, Undo); WorkspaceKit (recent projects, reopen at launch, live file watching); SecretsKit (Keychain, Secure Enclave SSH key, tokens, secret scanner); PolicyKit (approval tiers, tighten-only project rules, capability tokens, hash-chained audit log); Settings; plane mode; Acknowledgements.

Editor navigation: tabs (preview tabs, overflow past 8, ⌃Tab), quick open (⌘P), find in project (⇧⌘F), go to line (⌘L), go to symbol (⇧⌘O and `@` in the palette; `?` sends a task to the agent), and file operations in the navigator (new, rename, duplicate, delete after a checkpoint).

Open from the P1 bar: your hands-on editor checks; cloning from forges other than GitHub (GitLab, Forgejo, Origin) isn't tested.

## P2 plane-ready agent: mostly built

- **Models (ModelKit):** pinned, checksum-verified downloads (Tiny 0.5B, Standard 7B). Tiny drafts commit messages (0.19 s) and ghost text (~0.45 s after you stop typing).
- **Agent (AgentKit):** typed tools, policy on every call, journal and resume, a task branch and worktree per task, changeset review hunk by hunk, squash merge with an `Assisted-by` trailer. Agent pane on iPad, Agent and Changes tabs on iPhone.
- **Online models (start of P4):** Anthropic or any OpenAI-compatible API for agent tasks (Settings › Models), keys in the Keychain, consent per project with Face ID, routing Local / Online / Auto with plane mode forcing local. On the golden set, Claude Sonnet 5.5 passes **25/25** (~35 s a task) where the local 7B passes 18/25.
- **Quality:** golden task set, 25 tasks, run on the device with `-OmnieAgentEval`: **18/25 (72%)**, about 40 s a task, plateaued for the 4-bit 7B; what's left is the model's judgment. See `spikes/agent-p2.md`.
- **Security:** red-team corpus v1 (7 attack cases, real PolicyKit, approvals denied); it found and closed a symlink escape.

Open: an agreed pass rate on a larger task set (the router can already send what the local 7B can't do to an online model).

## P3 sandbox and tools: exit test passes

**The plane test passes on the iPad** (PLAN's P3 bar): a Vite-style three.js project is cloned and prepared online, then in plane mode the local 7B fixes it, its tests and type check pass, the preview and the Stage run, a commit is made and the push queues; with plane mode off, the push lands. 67–70 s end to end, unattended (`scripts/plane-test.sh`). See `spikes/plane-test-p3.md`.


- **RunKit:** JavaScript/TypeScript (Sucrase in JavaScriptCore, ES modules in WKWebView) and Python (Pyodide) run on the device with no network and a timeout; vitest- and pytest-compatible subsets run a project's own tests. The agent has `run_tests` and `run_script`.
- **WASI (wasm32-wasip1) programs:** RunKit's own preview1 layer passes **73 of 73** of wasi-testsuite on the iPad (6.1 s for the suite; the P0 spike's shim passed 55). Programs run in a worker in the sandboxed web view against the project: files load on first read, and what a program writes, moves or deletes is applied inside the project when it exits. Paths can't leave the directory they're resolved from, rights only shrink, no sockets, a memory cap, a timeout, and **fuel**: each module is instrumented at load so every call and loop iteration spends from a budget (20 billion units by default, about 10% slower), which stops runaways deterministically; the suite still passes 73/73 with it, on the iPad too. In the terminal: bundled `jq` (jq's language through jaq), `./tool.wasm`, and project tools in `tools/` or `.omnie/tools/` by name; the agent's `run_script` runs `.wasm` too. On the iPad, a jq query takes 166 ms.
- **Conflict resolver, agent proposals:** "Propose" asks the model (the agent's router: local in plane mode, consent before code goes online) to merge each conflict block from both sides and the lines around it; the result is marked "Proposed by …" for review, and a merge that used proposals carries an `Assisted-by` trailer. On the iPad the local 7B merged a two-file conflict correctly (1.4 s and 2.2 s per file: "Shows between 1 and 25 items", the raised limit kept beside the new constant). Repeated context in a small model's reply is trimmed.
- **Workspace spec (PLAN §8.2), device half:** tasks come from `.devcontainer/devcontainer.json` (`run.tasks`, comments allowed) or `package.json` scripts. `npm run <script>`, `npm test`, `yarn <script>`, `task <name>` and the palette's "Run task: dev/test/build" run them through the built-in shell, part by part for `a && b`, saying they ran on this iPad; `vite` opens the preview and `tsc` runs the type check. A task that needs a real toolchain (`docker`, `cargo`, `vite build`…) says it belongs on a remote host (P4). The spec's `image`, `forwardPorts`, `network.allow` and `deploy` are read for the remote half; the allowlist isn't given to the agent's policy (a cloned repo could otherwise grant itself network access).
- **Log viewer (in the terminal):** a text filter and an errors-only toggle; any line naming a project file and line (TypeScript errors, stack frames, Python tracebacks, uncaught errors, which now say where they were thrown) opens the file there; JSON lines expand to formatted JSON.
- **Terminal tab (TermKit):** built-in commands over the project (ls, cd, cat, grep, run, test, git status/log/diff, open), Run tests and Run file.
- **Preview:** a project's index.html live, TypeScript transpiled on the fly, reload on save. **DevTools-lite** below it: the console; every request the page made (from RunKit's scheme handler: status, kind, size, time, mocks marked; requests to the internet listed as blocked); and the DOM as an outline where tapping a node outlines it in the page and shows its size, box, font, colours and attributes.
- **Offline package cache, first tier:** three.js bundled and import-mapped, so `import * as THREE from "three"` works offline in previews, runs and tests.
- **Offline package cache, npm tier:** `npm install [name[@range]]` in the terminal (or Prepare for offline, per project) fetches packages and their dependencies from the registry, checks each against its integrity hash and unpacks it into Application Support. Previews, runs and tests then import them from the project's package.json with no connection: ES modules as they are, CommonJS wrapped as ES modules with named exports found statically. Checked with React 18 (server render), zod, date-fns, nanoid and lodash-es. On the iPad: `npm install zod` 0.39 s, a run that imports it 54 ms, a type check against its declarations 258 ms.
- **Offline package cache, Python tier:** `pip install [name…]` or `pip install -r requirements.txt` (or Prepare for offline) fetches Pyodide's own builds (numpy, pandas and the rest of its 357 packages, pinned by its lock file) from its CDN and pure-Python wheels from PyPI, each checked by sha256, with dependencies resolved (PEP 440 versions, PEP 508 markers evaluated for Pyodide). Scripts and tests load them from requirements.txt or pyproject.toml with no connection. On the iPad: `pip install numpy tabulate` 0.4 s, a script using both 1.2–1.4 s.
- **Stage:** glTF/GLB, OBJ and STL from the project in three.js, with a native performance HUD. Scene modules (`*.stage.js`/`.ts`, `export default ({ THREE, scene, onFrame }) => …`) run there too; shaders (`.glsl`, `.vert`, `.frag`, `?raw`) import as strings. Saving reloads the stage with the camera where it was, and shader compile errors land on the shader's line in the editor and in Problems. A scene inspector lists the objects (tap one in the viewport to select it) and edits transforms, visibility, material colours, roughness, metalness, opacity and shader uniforms live, until the next reload. The agent's read-only `stage_scene` tool sees the same scene graph (as loaded or last edited) and the HUD numbers. On the iPad: 60 fps (WKWebView caps animation frames at 60 Hz). Python starts and runs in under a second. See `spikes/runkit-p3.md`.
- **Tools tab (ToolsKit):** the snippet vault (SQLite with full-text search; "Save selection as snippet", insert at the caret; pinned snippets go to the agent with every task, and it has `snippets_search`), the diff tool (any two project files or pasted text, git's diff engine and the review's colors; "Compare open file with…" in the palette), HTTP client (`.http` files, secrets from the Keychain), API mock server (recorded responses, and routes generated from an OpenAPI or Swagger spec, JSON or YAML, in the project, served to previews), SQLite browser (read-only by default) and the Patterns lab (JSON with jq queries through the bundled WASI jq; YAML shown as JSON and JSON turned into YAML; regex in JS and Swift flavors with a piece-by-piece explainer; a cron explainer with the next runs, deterministic as PLAN asks).
- **Offline docs:** DevDocs bundles (MDN JavaScript, DOM, CSS, Python, Node, three.js, React, NumPy, pandas, git, and the rest of its 837) downloaded from Help › Search docs (⇧⌘D, which starts with the word at the caret), then searched and read with no connection; links between pages work, scripts don't run. The agent has `docs_lookup` when any are installed. DevDocs publishes no checksums, so the download's sha256 is recorded instead.
- **Markdown + Mermaid preview** in the Preview tab for the open `.md` file; it follows the caret (each block knows its source line) and exports to a paginated A4 PDF beside the file.
- **Type checking:** TypeScript 5.9 runs offline over the whole project (tsconfig.json honoured; without one, Vite-like defaults with every file a module; with the declarations of packages in the offline cache) when it opens and after saves: underlines in the editor, an error count in the status strip, a Problems list (⇧⌘M). The agent has `check_types` in TypeScript projects.

Open: more bundled WASI tools, PyPI packages with compiled code that Pyodide doesn't build, the Stage's "Write to code" for inspector edits.

## How to check things yourself

- Debug launch arguments (debug builds): `-OmniePlaneTest <bare repo in Documents>`, `-OmnieWasiConformance`, `-OmnieOpenFolder <path in Documents>`, `-OmnieRunTests`, `-OmniePreview`, `-OmnieAgentDemo`, `-OmnieAgentTask "<goal>"`, `-OmnieAgentEval <label>`, `-OmnieModelSmoke`.
- Packages: `swift test` in each `packages/*` (EditorKit runs on the simulator: `xcodebuild test -scheme EditorKit`).
- Vendored inputs (gitignored): `scripts/build-git-deps.sh`, `scripts/vendor-grammars.py`, `scripts/vendor-runkit.sh`, `scripts/vendor-wasi-spike.py`.

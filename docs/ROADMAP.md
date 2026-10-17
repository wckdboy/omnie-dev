# Omnie Dev — IDE roadmap (iOS / iPadOS)

Engineering plan for the editor-as-a-production-IDE. Grounded in the code that exists today
(see [STATUS.md](STATUS.md)) and the architecture in [PLAN.md](PLAN.md).

**Hard constraints (they shape every decision):**
- **Native, 120 Hz.** Typing, caret and scroll never go through a web view, never animate.
- **Offline-first.** No network on the critical path; plane mode is a mode, not an error.
- **App Review 2.5.2.** No runtime extension/plugin loading. Capability grows by curation, not by a
  marketplace.
- **iPad-first, iPhone lighter.** One codebase, two shells (`IDE` / `Vibe`).

Each milestone ships behind its own TestFlight build and its own tests.

---

## M0 — Trust (in flight)
Make the suite and the sandbox dependable before adding surface.

| Deliverable | Where | Done when |
|---|---|---|
| Sandbox stall root-caused, heartbeat + real error surfaced, retry only on a real stall | `RunKit` (`SandboxWorker`, `pylanguage-worker`, `python-worker`) | CI green twice in a row with no manual retry; a stall fails in seconds with a reason |
| Biometrics require a passcode; keyed audit chain; secret scanner covers long lines; npm cache path containment | `PolicyKit`, `SecretsKit`, `RunKit/Npm` | Audit findings closed; tests added |
| Perf budgets enforced (typing latency, scroll hitches, fold/minimap/find over a 1 M-char file) | new `EditorPerfTests` + `-OmniePerf` | Nightly run fails on regression |

## M1 — Editor parity (the daily reach)
| Deliverable | Where | Notes |
|---|---|---|
| **⌘D select-next occurrence**, real selections | engine fork `omnie-dev-editor-engine` → 0.7 | Needs selections, not just zero-length carets. Highest-value parity gap |
| **Fold-all cost** (≈0.9 s for 2 000 folds) | engine fork | The perf harness shows it is entirely the engine's `foldedRanges` setter (layout); building the ranges is 0.4 ms. Worth an engine-side fix |

> The two engine changes above are written up with APIs and replayable numbers in
> [engine-tickets.md](engine-tickets.md).
| Find/replace depth: **regex**, **whole word**, replace-in-selection, search history | `EditorKit/Search.swift`, `FindBar` | Builds on the find shipped in 1.6.0. All four shipped in 1.7.0 (regex/whole word in 1.6.0; Find in Selection ⌥⌘L and search history in 1.7.0) |
| Auto-close brackets/quotes, smart indent, matching-bracket jump | engine | Ergonomics that separate "editor" from "text box". Matching-bracket jump (go and select) shipped in 1.7.0; auto-close and smart indent are engine-side, in the queue |
| Snippet placeholders with Tab stops | `ToolsKit` snippets + editor | The vault exists; make it interactive. Shipped in 1.7.0 (`SnippetExpansion`, `SnippetSession`) |
| Word-wrap / whitespace / indent-guide toggles, editor ruler | `EditorKit` | Mostly presentation |

## M2 — Languages
| Deliverable | Where | Notes |
|---|---|---|
| Go, Rust, C/C++, Java **highlighting + fences** | `LangKit` + `scripts/vendor-grammars.py` | Vendoring is scripted; Swift already ships |
| **Workspace symbol search** (⇧⌘T) across all files | `LangKit/Outline` + a project index | Reuses the type-checker walk |
| **LSP-over-WASM bridge** for one language | `RunKit` sandbox + a wasm LSP (e.g. rust-analyzer) | The realistic path past "textmate grammar" |
| Python: Pyright-grade diagnostics (optional), keep Ruff | `RunKit` | Ruff covers lint; keep it |

## M3 — Run & debug
| Deliverable | Where | Notes |
|---|---|---|
| JS/TS **debugger**: breakpoints, step, variables, console | `RunKit` (JSContext/WKWebView + CDP-style protocol) | The single biggest "IDE" gap. **Landed**: `Debugger` (RunKit) pauses synchronously in a worker, with breakpoints, step over/into/out, locals and the call stack over the project's own modules; a gutter dot (F9) and the Debug panel (F5/F10/F11/⇧F11/⇧F5) are wired in. npm-package loading is the next piece (`DebuggerTests`, `DebuggerUITests`) |
| Python debugger over Pyodide (`pdb`) | `RunKit` | Reuses the Python worker |
| Test explorer: run/failed/rerun, per-test output | `RunKit` + a Problems-style pane | Vitest/pytest subsets already run |

## M4 — Workspace & version control
| Deliverable | Where | Notes |
|---|---|---|
| **Replace in project** (preview + apply, with a checkpoint first) | `WorkspaceKit/ProjectSearch`, UI | Pairs with Snapshots for safety |
| Multi-root / multi-folder workspaces | `WorkspaceKit`, `Shell` | VS Code users expect it |
| Remote dev: SSH + **tmux control mode**, remote Podman runner + deploy | `RunKit`, new RemoteKit | PLAN §12; the long pole for real projects |

## M5 — Agentic depth
| Deliverable | Where | Notes |
|---|---|---|
| Repo-wide context: local embedding index + retrieval | `AgentKit` | Raises the local model above 18/25 on the golden set |
| Changeset **diff preview dialog** before apply; one-tap undo via Snapshots | `AgentKit`, `Shell` | Makes the agent safe to use broadly |
| Router on a measured quality signal (per task kind) | `ModelKit` | Replaces the heuristic "Auto" |

## M6 — Platform polish
| Deliverable | Where | Notes |
|---|---|---|
| iPhone parity for the core (editor, git, run, agent) | `Vibe` | Not a full workbench; the agent-first loop |
| VoiceOver + Dynamic Type pass for every new surface | app-wide | PLAN §19; keep the audit tests green |
| Simple-mode onboarding for new users | `Shell` | Graduation path into the workbench |

---

## Cross-cutting
- **Every bug gets a failing test** before the fix (5 added in the 1.6.0/1.6.x cycle).
- **Release hygiene:** bump `MARKETING_VERSION` per shippable; one build per change set; a
  `CHANGELOG.md`; `scripts/clean.sh` for the derived-data growth that aborted an archive.
- **CI:** split the packages job, cache hard, quarantine the WebKit sandbox tests behind a
  retry-once policy with a clear "stalled" signal; keep UI tests on main.

## Recommended order
1. **M0.1** sandbox stall → 2. **M1 find/replace depth** → 3. **M1 ⌘D** (engine 0.7) → 4. **M2 Go/Rust
highlighting + workspace symbols** → 5. **M3 JS debugger**.

# Changelog

Omnie Dev ships as TestFlight builds; each entry is a marketing version with the build number App
Store Connect saw. Versions follow the plan in [docs/ROADMAP.md](docs/ROADMAP.md); what is built and
measured today is in [docs/STATUS.md](docs/STATUS.md).

## Unreleased

**Languages**
- **Java**: tree-sitter-java highlighting and outlines for `.java`, joining Swift/TypeScript/JavaScript/Python/Go/Rust/C/C++ (vendored and hash-pinned by `scripts/vendor-grammars.py`).
- **Markdown**: `.md` files highlight with tree-sitter-markdown (headings, code fences, links), and a fenced block is highlighted as the language it names (```` ```java ````, ```` ```python ````, …). This is the editor's first use of the engine's injected-language path, so an HTML document's CSS and `<script>` highlight too.

**Tests**
- **Test explorer**: the Tests panel lists one row per test (pass/fail, duration, the failure's first lines) grouped by file, with **Run all**, **Run failed** (only the files that had a failure, keeping the other files' results), a **failed-only** filter and a per-file ⟳. Tapping a row opens the test's **full output** — the assertion message and stack, not the row's four lines — with **Run again** for that one test and **Open file**. RunKit's vitest subset and its pytest shim both take a test name to run one, so a test can be run again by itself.

**Workspace**
- **Multi-root workspaces**: **Add folder to workspace…** (File, or the button at the foot of the navigator) puts another folder beside the project. The navigator shows each added folder as its own section under a header that removes it again (the status strip counts them, `+N`); quick open, find in project and replace cover every folder, and a file in an added folder is named by it (`uitest-extra/extra.ts`). Files from added folders open, edit and save as usual; each folder is watched like the project's own, and the set — with the file you had open in it — is remembered per project by bookmark across relaunches. **Git follows the file**: an added folder that is its own repository is marked in the navigator, and the git panels, blame and the status strip switch to its repository while you edit in it, back to the project's own when you leave. Tasks, the agent and type-checking still run on the project's folder.

**Editor**
- **Accessibility across the panels and sheets**: Apple's accessibility audit now runs over every panel (Agent, Debug, Tests, Tools, Terminal, Preview, Stage) and over the sheets (Problems, Snapshots, Welcome, palette, quick open, projects, Settings, commit, branches) — **both enforce**. The first pass fixed the Tests buttons' and the Tools tab row's hit areas, the terminal's clipped filter field, and the palette's background (opaque now, so its contrast doesn't depend on what is behind it).
- **Whitespace, indent guides and a ruler**: View gains **Render whitespace** (spaces as dots, tabs as arrows), **Indent guides** (a hairline at each level of indentation, on by default) and a **Ruler** column guide at 100 characters. The engine draws them through its decoration layer (patch 0021, `omnie-dev-editor-engine` 0.7.2).
- **Smart indent**: a line break inside a block indents by the file's unit (a tab, or its smallest width — two spaces by default), and Enter between `{}` opens the block. LangKit supplies each language's tree-sitter indentation rules and EditorKit builds the engine's `TreeSitterIndentationScopes` from them (engine 0.7.1).
- **Multi-selection**: ⌘D now selects the word and then adds the next occurrence as a **real selection**, so typing or backspace replaces every one in a single undo step (engine 0.7.0, patch 0019: `TextView.selections: [NSRange]`). ⇧⌘L selects every occurrence at once; Esc, a tap or an arrow collapses to one. An IME's committed text lands at every selection too (engine 0.7.3, patch 0022).
- **Auto-close brackets and quotes**: typing `(`, `[`, `{`, `"`, `'` or `` ` `` brings its partner and parks the caret between; a closer typed in front of one already there steps over it; a selection is wrapped. This already worked through the engine's `characterPairs` — the fix (engine patch 0017, `omnie-dev-editor-engine` 0.6.10) stops it doubling, so `(` before `)` now gives `()` instead of `())`.
- **Fold-all is 10× faster on a large file**: hiding 2 000 folds in the ~0.8 M-character fixture went from 0.86 s to 0.086 s (engine patch 0018, 0.6.11) — the hidden rows' heights are applied as one batch and the line tree's totals recomputed in a single pass, instead of walking each line's ancestors.

**CI and tests**
- The packages' tests run as one parallel job per package (a `vendor` job builds the native inputs once — libgit2, the tree-sitter grammars, RunKit's bundles and the WASI spike's assets — and every test job restores them and the SwiftPM caches); RunKit's WebKit suites are retried once behind a "stalled" warning; EditorKit (with the editor performance budgets, now including **scrolling**) is its own simulator job that the nightly run gates on. Two long-standing holes are closed: the UI job's `| tail` no longer hid its exit code, and the WASI spike's assets (needed to build the app, and for the WASI conformance test) are vendored again after the upstream suite moved.

**Design**
- **Sheets on the app's own surfaces**: every sheet now draws on the app's own background, navigation bar and row colours (`DesignKit.sheetChrome()`) instead of the system's grey — the same surfaces the palette's text roles are tested against, and one look for the whole app.
- **Tertiary text meets AA everywhere**: dark `text.tertiary` on the raised panel was 4.34:1, so both themes' tertiary grey were nudged to clear 4.5:1 on every surface — chrome, editor, pane and raised (dark `#828A94`, light `#666D77`) — and a DesignKit test now checks the text roles on all four.

**Agent**
- **One-tap undo**: the app snapshots the project just before an accepted changeset lands, and the agent pane then offers **Undo** (or "Undo agent changes" in the palette) to put the project back the way it was. Because a restore snapshots the current state first, the undo is itself undoable.

**Simple mode**
- **Graduate to the workbench**: Simple mode shows a **Workbench** button in the status strip (and a "Graduate to the workbench" command) that leaves the plain file list and editor for the standard layout, with the agent, terminal and docks to hand; a one-time hint points at it.

**Debugger (RunKit core, PLAN.md §5.3)**
- RunKit's debugger runs a project's own JavaScript/TypeScript modules with a hook at the start of
  every statement and around every function body: breakpoints (per file and line, with conditions),
  step over / into / out / continue / stop, the locals in scope at each stop, the call stack, and
  evaluation in the paused frame (with a watch list). Stopping is synchronous — the sandbox worker
  parks on a request the app holds open and reads the chosen action back from its response, so the
  JavaScript stack and its locals are still live when the pause is shown. Imports of a package in the
  offline npm cache load from there (uninstrumented: a breakpoint inside a package doesn't stop).
- The editor draws a breakpoint as a dot in the gutter (tap the gutter, or F9; a fold chevron in
  the same strip still folds — the two gutter taps run beside each other), and F5 starts (or
  continues) a session on the open file. The Debug panel lists the call stack (tap a frame to open
  it) and the locals, with Continue / Step over / Step into / Step out / Stop and the console.
  F10 steps over, F11 steps in, ⇧F11 steps out, ⇧F5 stops. The panel's Evaluate field runs an
  expression in the paused frame — where the statement stopped, so it sees the locals — and shows
  the result (the runtime holds the stop open while it evaluates). **Watch** expressions are
  re-evaluated at every stop, and a breakpoint can carry a **condition** (Debug › Edit breakpoint
  condition…), which is evaluated in the frame and stops only when it holds (a conditional dot is
  amber). Breakpoints and their conditions are kept with the session, so a project reopens with them.
- The same debugger runs **Python** (Pyodide): a line tracer (`sys.settrace`) stops at a breakpoint
  (conditions too) or while stepping over/into/out, and shows the locals, the call stack and an
  expression evaluated in the paused frame, over the same held pause request — so the Debug panel is
  the same for either language. Packages from the offline Python cache load uninstrumented.

## 1.7.0 — 202610171

The "editor parity and trust" release: the large-file editor held to budgets, find/replace depth,
the remaining app-side editor ergonomics, and the guarantees that make the sandbox dependable.

**Editor**
- Find and replace in the open file, with whole-word and regular expressions, replace one/all.
- Find in Selection (⌥⌘L) and a search history kept across launches.
- Select next occurrence (⌘D), and Change all occurrences (⇧⌘L).
- **Go to matching bracket** (⇧⌘\) and **Select to matching bracket** (⌃⇧⌘\).
- **Snippet Tab stops**: `$1`, `${1:default}`, `${1|a,b|}` and `$0` become placeholders you Tab
  through — typing fills the stop and carries the rest of the snippet along; Esc leaves it.
- Sort lines (ascending/descending), join lines (⌃J), insert line above/below (⇧⌘↩ / ⌘↩), delete all
  left/right, trim trailing whitespace, and Transform to uppercase/lowercase/title case (on the
  selection or the word at the caret). Copy path / Copy relative path for the open file.
- Toggle breadcrumbs and sticky scroll (with word wrap and the minimap) in View.
- Convert indentation to spaces or tabs over the whole file.
- Save all (⌥⌘S): the editor's file and the split editor's.
- Expand Selection (⌃⇧→) and Shrink Selection (⌃⇧←): a caret grows to the word, the brackets around
  it, the line, then the document.
- Go to next/previous problem (F8/⇧F8): walk the project's type-check and lint diagnostics in order,
  opening the file when the problem isn't the one on screen.
- Go back / Go forward (⌃- / ⌃⇧-): the navigation history of file switches and in-file jumps.
- Go, Rust, C and C++ highlighting and outlines, alongside Swift/TypeScript/JavaScript/Python.
- Go to symbol in the workspace (⌘T).
- Replace in project (⇧⌘F), which takes a snapshot first.

**Editor performance**
- A performance harness for the large-file editor (`-OmniePerf`), with machine-tolerant budgets for
  typing latency, seek, find over 1 M characters, fold-all, minimap, and bracket matching. The two
  engine-side changes it argues for are written up in [docs/engine-tickets.md](docs/engine-tickets.md).

**Trust**
- The RunKit sandbox stall is root-caused: a stalled web view reports the phase it stalled in and
  fails in seconds with a reason; a real run retries once.
- Security round two: biometrics require a passcode, the secret scanner covers whole long lines, and
  the npm cache path is confined.
- The PolicyKit audit log is hash-chained and signed with a Keychain key.

**Workbench**
- A Tests panel: a test explorer over RunKit's results, run one file or all, see pass/fail per test.
- Snapshots: a project safety net that doesn't need git.
- Simple mode: a plain file list and editor for people who don't want the workbench yet.

## 1.6.0 — 202610106

- Code folding: indentation blocks and Markdown headings, gutter chevrons, Fold/Unfold and Fold
  all/Unfold all, folds kept per file across relaunches.

## 1.5.0 — 202610105

- Format Document for Python with Ruff's formatter (Black-compatible), honouring the project's
  `line-length`; one undo step.
- Python problems from Ruff's linter, with the status strip counting warnings as VS Code does.

## 1.4.0 — 202610104

- Format Document (⇧⌥F) with Prettier for JS/TS/JSON/CSS/HTML/Markdown/YAML, honouring the project's
  own options; one undo step; format on save.
- Multiple cursors: add cursor above/below (⌥⌘↑/⌥⌘↓), change all occurrences (⇧⌘L).

## 1.3.0 — 202610103

- Python code intelligence with Jedi (pure Python, in Pyodide): definitions, references, rename,
  signatures, docs and completions, offline.

## 1.2.0 — 202610102

- Code intelligence for TypeScript and JavaScript, offline: the TypeScript language service fed the
  editor's unsaved text — go to definition, find all references, rename symbol, type and docs, and
  completions as you type.

## 1.1.0 — 202610101

- The workbench as VS Code users expect it: nothing hides under the keyboard, every panel closes and
  comes back, editor tab management, the line commands (⌘/, ⌥↑/⌥↓, ⇧⌥↑/⇧⌥↓, ⇧⌘K, ⌘]/⌘[), zoom, and
  projects (new/switch/close) with a start page.

## 1.0.0 — 202610093

- The full offline IDE: shell, command palette and menus; the code editor; GitKit (clone, history,
  branches, conflicts, Sync); WorkspaceKit; SecretsKit; PolicyKit; Settings; plane mode.
- The plane-ready agent: on-device models, typed tools with policy, task branches and worktrees,
  changeset review hunk by hunk, and a golden task set it is measured against.
- P3 sandbox and tools: JavaScript/TypeScript and Python run offline with a timeout; WASI programs
  with fuel and memory limits; the terminal; the preview and Stage (three.js, AR); the Tools tab
  (snippets, diff, HTTP client, mocks, SQLite, Patterns); offline docs; TypeScript type checking.
- Pull requests on Forgejo/Gitea, GitLab and GitHub (HostKit).
- v1.0 bar: an 8-round memory soak passes on the iPad; the bug run's fixes are in.

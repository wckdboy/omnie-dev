# Changelog

Omnie Dev ships as TestFlight builds; each entry is a marketing version with the build number App
Store Connect saw. Versions follow the plan in [docs/ROADMAP.md](docs/ROADMAP.md); what is built and
measured today is in [docs/STATUS.md](docs/STATUS.md).

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

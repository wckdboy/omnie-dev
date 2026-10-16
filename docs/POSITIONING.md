# Omnie Dev — description, brand and audience

Positioning for the app. Grounded in the manifesto and design system in [PLAN.md](PLAN.md) §2–3 and the
tokens in [`brand/tokens.json`](../brand/tokens.json); where they disagree, they win. This file is the
marketing-facing summary: what it is, how it sounds, and who it's for.

> Name caveat: "Omnie-dev" still needs a trademark and App Store name check before any public use
> (PLAN §2.4). The caret mark doesn't depend on the name, so a rename costs nothing visually.

---

## 1. Description

### The one line
**A native, offline-first IDE for iPad — with an agent you can see.**

### The elevator (25 words)
Omnie Dev is a native code editor and dev environment for iPad. It runs JavaScript, TypeScript,
Python and WebAssembly offline, keeps your work in git on any host, and pairs you with an AI agent
that proposes changes you review line by line.

### The tagline options
- **Code on the plane. Ship from the iPad.** *(the plane is the product's home turf)*
- **Two authors. One file. You always know who wrote what.**
- **An IDE that works when the network doesn't.**

### App Store — subtitle (≤ 30 characters)
`Native IDE for iPad. Offline.`

### App Store — promo text
Write, run and review code on your iPad — on a plane, in a café, at a desk. A native editor with a
local AI agent that proposes changes you approve. No account, no cloud in your code path.

### App Store — description
Omnie Dev is a code editor and development environment built for iPad, in the tradition of Swift
Playgrounds, Pythonista, a-Shell and Code App — but native, offline-first, and with an agent that
shows its work.

**Write natively.** A real Core Text editor at 120fps: tree-sitter highlighting, code folding,
multiple cursors, find and replace, go-to-definition, references, rename and completions for
TypeScript, JavaScript and Python. No web view. It feels like the system, because it is.

**Work offline — on purpose.** Run JavaScript, TypeScript, Python and WebAssembly programs with no
network. Tests run in a sandbox with time and memory limits. Preview a page, a Markdown file or a 3D
scene. Install packages from the registry once and keep them offline. Being disconnected is a normal
mode here, not an error.

**Pair with an agent that's on a leash.** The agent reads your project, proposes a changeset on a
separate branch, runs the tests in the sandbox, and explains itself. Nothing lands until you review
it — hunk by hunk. Human work is cyan; agent work is violet and a second typeface, so you always see
who wrote what.

**Git that can't lose work.** Checkpoints are automatic, undo is universal, and the timeline reads
like a log, not a spellbook. Clone over SSH (keys in the Secure Enclave) or HTTPS, work with any
forge — Forgejo, Gitea, GitLab, GitHub — and push queued changes when you're back online.

**Take a snapshot, not a chance.** Before a risky change, take a snapshot: a copy of the project kept
outside it. Restore in one tap. It works in any folder, with or without git.

**Few tools, sharp tools.** A snippet vault, diff tool, HTTP client, API mock server, SQLite browser,
a regex/JSON/YAML/cron lab, offline documentation, and a three.js Stage. A dozen excellent built-in
tools beat five hundred mediocre ones.

**Simple or deep.** Turn on Simple mode for a clean file list and an editor. Turn it off for the full
workbench: docks, terminal, timeline, agent. Nothing is hidden, everything closes and comes back.

Two things it deliberately isn't: it doesn't build Swift or iOS apps on device, and it has no plugin
marketplace. Curation is the product.

### It is / it isn't
| It is | It isn't |
|---|---|
| A native iPad IDE | A web-view editor in an app wrapper |
| Offline-first, plane-ready | Cloud-dependent |
| Agent-assisted, human-approved | Agent-autonomous |
| Host-agnostic git | GitHub-locked |
| A curated dozen tools | A plugin marketplace |

---

## 2. Brand

### Name and wordmark
**Omnie Dev** (repo shorthand: Omnie-dev). Wordmark set in SF Pro, semibold, sentence case. The mark
never includes `</>`.

### The idea
**A precision instrument.** Graphite surfaces, one signal color, and nothing moves unless you moved
it. Cockpit, not toy.

### The signature: two visible authors
Human work is the **Ion** cyan accent. Agent work is a reserved **violet** plus the **Monaspace
Xenon** typeface. You can always see who wrote a line — in the gutter, the diff, the blame column and
the status strip. This is the brand's one memorable idea. Everything else stays quiet so it can land.

### The mark and icon
A **caret**: a vertical bar with a one-unit offset notch that reads as both cursor and seam. The icon
is a graphite squircle with the caret in Ion cyan glass on its own layer, in light, dark, clear and
tinted variants. Never: gradient backgrounds, robots or sparkles for AI, a `</>` glyph.

### Color
Graphite neutrals in five surface steps (chrome, editor, pane, raised, hairline); one Ion accent; one
reserved agent violet. Status colors: ok green, warn amber, error red. **Color appears only when
something needs attention — an idle, clean state is grey.** Syntax highlighting never uses violet.
Contrast is measured against the editor surface and every text color passes its target (4.5:1 dark
and light, 7:1 high contrast).

### Type
- **UI:** SF Pro, Dynamic Type, never bundled.
- **Code:** Monaspace Neon, `calt` on, fallback SF Mono.
- **Agent:** Monaspace Xenon, metric-compatible with Neon so the grid never shifts — used *only* for
  agent-authored prose, plans and ghost suggestions.

### Motion, sound, density
An 8.3 ms frame budget for 120Hz. Typing, the caret and scrolling are never animated. Only the
agent's "thinking" state breathes (and stops under Reduce Motion). Silent by default; feedback goes
through Pencil Pro. Density follows your hands and switches automatically with the input device.

### Voice
Calm, exact, terse, a little dry. Sentence case, verbs first, numbers instead of adjectives. No
exclamation marks, no "Oops", no apologising, and never talk about the AI as a person. Every error
says what happened, why, and the one next action.

| Say | Don't say |
|---|---|
| Push 3 commits | Something went wrong! |
| Agent wants to edit 4 files | AI is thinking really hard… |
| Offline. Using local model. | Awesome, all done 🎉 |
| Build failed: missing module `three`. Install from cache? | Oops, that didn't work |

### Feature names (the glossary)
Product terms are plain and specific: **Plane mode**, **Checkpoint**, **Timeline**, **Changeset**,
**Snapshots**, **Stage**, **Simple mode**, **Focus mode**, **Sandbox**, **WASI container**. We say
"WASI container" or "remote Podman", never "Docker", unless it's real.

### What the brand refuses
A plugin marketplace; a web-view editor as the main surface; pretending to be Docker on device; an
agent that pushes, deploys, deletes or touches secrets without you; a default forge; a staging area
shown by default; a cloud backend on the code path; telemetry on by default; gamified AI (sparkles,
mascots, "Thinking really hard…").

---

## 3. Target user

### Primary — the solo builder who is done with the laptop
An indie developer, indie hacker or product engineer who treats the iPad as a real computer. They
work on trains, planes and kitchen tables as often as a desk. They know git, they care about where
their code lives, and they're quietly leaving GitHub for their own forges. They want one tool that
writes, runs, tests and ships — and they do not want a remote desktop to a Linux box just to fix a
function.

- **Wants:** real keyboard feel; offline; their own git host; AI help that doesn't surprise them.
- **Fears:** losing work; a "toy" that can't run tests; an AI that rewrites code behind their back; a
  subscription that sends their code somewhere.

### Secondary — the learner who shouldn't start in a cockpit
Someone new to code who wants a friendly editor today and room to grow tomorrow. They start in
**Simple mode** — a file list and an editor — and graduate to docks, terminal and the agent when they
want them. They learn by running things and seeing the result, not by reading documentation tabs.

### Secondary — the privacy-conscious professional
A consultant or security-minded engineer who can't put client code in someone's cloud. Bring-your-own
keys, bring-your-own hosts, **plane mode** that actually blocks the network, secrets in the Keychain,
signing in the Secure Enclave, and no telemetry by default. The agent runs a local model on the
device when the network can't be trusted.

### Secondary — the agent-curious skeptic
Interested in AI coding help, allergic to handing over control. They want to see the plan, the diff
and the tests; to accept one hunk and reject the next; and to undo the whole thing with one tap. The
two-authors signature is for them.

### Jobs to be done
1. **When I'm away from my laptop,** I want to keep building, so the project isn't stalled.
2. **When there's no network,** I want to run and test my code anyway.
3. **When an agent touches my code,** I want to see exactly what it did before it counts.
4. **When something breaks,** I want to get back to a known-good state without thinking about git.
5. **When I'm learning,** I want an editor that isn't a toy and isn't a cockpit.

### Anti-personas (who it's not for)
- Building or shipping **Swift/iOS apps** on device (Swift Playgrounds owns that; you remote to a Mac).
- Teams needing **real-time collaboration** or a browser IDE.
- Anyone who wants a **plugin ecosystem** — extensions are out by design.
- Heavy **native toolchain builds** (Cargo, Docker, `vite build`) — those belong on a remote host.

### Where they come from
Code App (wants it to feel native), Working Copy (wants runtimes and an agent), a-Shell (wants an
editor and a UI), Pythonista (wants more than one language and git), Swift Playgrounds (wants their
own stack), VS Code (wants it on the device, offline).

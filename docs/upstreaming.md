# Upstreaming the engine patches to Runestone

`omnie-dev-editor-engine` is a hard fork of [simonbs/Runestone](https://github.com/simonbs/Runestone).
Its [`PATCHES.md`](https://github.com/wckdboy/omnie-dev-editor-engine/blob/main/PATCHES.md) marks each
patch with an upstream status; this is the plan for the ones marked **Candidate for upstream**. Fixes
worth sharing go upstream first.

## Ready to offer

Each branch is based on the fork's `upstream` mirror (Runestone itself) and holds **only that change
plus a test**, so it can be reviewed on its own. All three are pushed to the fork.

| Patch | Branch | What it fixes | Reference |
|---|---|---|---|
| 0002 | `upstream-0002` | `UITextInput.text(in:)` answered `nil` for an empty or end-of-buffer range, which crashes Writing Tools on iOS 26.1 on Return at the end of the buffer. The UITextInput boundary now answers `""` (internal callers keep the optional). | Fixes [#413](https://github.com/simonbs/Runestone/issues/413) |
| 0017 | `upstream-0017` | Typing an opening bracket in front of its closer doubled it — `(` before `)` gave `())`. When the character after the caret already closes the pair, the typed bracket is inserted on its own. | — |
| 0020 | `upstream-0020` | The tree-sitter indent controller compared a node's **byte** column (the parser reads UTF-16LE, so it is twice the character offset) with the caret's UTF-16 column, so a block looked like it closed on the caret's line and Enter after `{` inserted a blank line. | — |

Open a PR against `simonbs/Runestone:main` from the fork branch:

- <https://github.com/simonbs/Runestone/compare/main...wckdboy:omnie-dev-editor-engine:upstream-0002>
- <https://github.com/simonbs/Runestone/compare/main...wckdboy:omnie-dev-editor-engine:upstream-0017>
- <https://github.com/simonbs/Runestone/compare/main...wckdboy:omnie-dev-editor-engine:upstream-0020>

## Larger candidates

Offering these is a judgement call: they are bigger, or they change behaviour enough that upstream
may want them behind a flag. Each is a topic of its own in `PATCHES.md`.

| Patch | What it is | Why it may wait |
|---|---|---|
| 0004 | One shared `DefaultTheme.placeholder` instead of one per line controller | Perf; small, could go with 0009/0010 |
| 0005 | `ViewReuseQueue` parks reused line views rather than removing and re-adding them | Perf (scroll hitches); a behaviour change in view reuse |
| 0006 | `RedBlackTree` uses direct field access instead of `KeyPath` in a hot path | Perf; tiny, easy to review |
| 0009 + 0010 | Each visible line's y-position is computed once per layout pass, and carried forward | Perf (per-keystroke); best offered together |
| 0013 | `layoutSubviews` announces a pending selection change once | Perf; touches IME behaviour, so it wants a hands-on Korean/Japanese check first |
| 0007 + 0008 | Incremental tree-sitter reparse off the main thread, and a settable `inputView` | The largest; `PATCHES.md` suggests upstreaming behind a flag |
| 0014 | VoiceOver: the input view is an accessibility element that reads line by line | A feature, not a fix; needs a hands-on VoiceOver pass |
| 0015 | Host-provided items first in the edit menu | A feature; may want an agreed API shape first |

## Not candidates

- **0001** removes private API use in a way that changes behaviour (no autocorrect suggestion menu in
  code views) — a deliberate difference, not a fix.
- **0011, 0012, 0016, 0018, 0019, 0021** are Omnie-specific: the decoration layer, the multi-cursor
  prototype, code folding, batched fold heights, multi-selection and indent guides.

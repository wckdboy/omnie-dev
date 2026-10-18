# Editor engine tickets (`omnie-dev-editor-engine`)

Changes that belong in the engine fork, not in the app. Each is justified with numbers or a spec
measured from this repo, and each has an app-side plan.

**Status:** #2 (fold-all cost) landed in **0.6.11** and #3 (auto-close) in **0.6.10**, each with
engine tests. #1 (multi-selection, for ⌘D) is the remaining one — the public API change that bumps the
engine to **0.7.0** and `packages/EditorKit/Package.swift`'s `exact:` version with it.

---

## 1. Multi-selection (for ⌘D, Select next occurrence)

**Today.** The engine exposes zero-length cursors: `textView.additionalCaretLocations`. `⌘D`
(`WorkspaceModel.selectNextOccurrence`) uses them, so a second press adds a *cursor* at the next
occurrence and typing **inserts** there — it does not **replace** the occurrence, and there is no
per-occurrence selection highlight. `⇧⌘L` ("Change all occurrences") works around this by deleting
the word and leaving a cursor at each site.

**Ask.** A public multi-selection API, one range per selection:

```swift
// Runestone TextInputView / TextView
public var selections: [NSRange] { get set }   // length 0 is the plain caret
```

Requirements:
- Each selection has a **length** (a highlighted occurrence), and the set is kept in sync with edits
  and undo like `selectedRange` is today.
- Setting `selections` does not fire `onSelectionChange` per element (one notification).
- `additionalCaretLocations` can remain as `selections.filter { $0.length == 0 }.map(\.location)`, or
  be deprecated in favour of `selections`.

**App side once landed.** `selectNextOccurrence()` appends the word range to `selections` instead of
a caret location; typing replaces every occurrence; Esc collapses to one selection. `MultiCaret` and
the multi-caret engine patch (0012) stay as the caret-only fallback while the API stabilises.

**Tests.** Extend the engine's multi-caret/keystroke tests: N selections, one edit per site, one undo
restores all, and the caret state after an edit that changes offsets.

---

## 2. Fold-all layout cost — landed

**Measured** by `EditorKitTests/PerformanceTests` on a ~0.8 M-character, 20 000-line file with
~2 000 foldable blocks:

| Step | Before | After |
|---|---|---|
| Build the fold ranges (app) | 0.18 ms | 0.18 ms |
| `textView.foldedRanges = ranges` (engine, iPad simulator) | **0.87 s** | **0.086 s** |
| Same, CI runner | 8.0 s | under the 5 s budget |

**What it was.** Not layout invalidation per range: the time was all in `updateHiddenRowsIfNeeded`,
which set each of the ~16 000 hidden rows' heights through the line tree, and every set walked the
node's ancestors to update the tree's totals (rows × depth).

**The fix (patch 0018, `omnie-dev-editor-engine` 0.6.11).** Collect the height changes, apply them in
one batch, then recompute the tree's totals in a single bottom-up pass. The cost is now linear in the
rows: 355 ms → 89 ms for 2 000 folds in the engine test.

**Tests.** `RunestoneTests/FoldPerformanceTests` (2 s budget, 89 ms measured), and the app's
`PerformanceTests.foldAllCostSplitsCleanly` budget tightened from 30 s to 5 s.

---

## 3. Auto-close brackets and quotes (and skip-over) — landed

Upstream Runestone already does most of this: `TextView.insertLeadingComponent` inserts the pair and
puts the caret between them, `skipInsertingTrailingComponent` moves the caret over a closer already
there, and a non-empty selection is wrapped — all gated by `characterPairs`, which EditorKit sets
(`CodeEditorController.pairs`). It runs through the typed-insertion path, so it is one undo step, and
marked text (IME) is left alone.

The gap was **double-closing**: Runestone always added the trailing component, so typing `(` in front
of an existing `)` gave `())`. **Patch 0017** (`omnie-dev-editor-engine` 0.6.10) now leaves the typed
bracket to insert on its own when the character after the caret already closes the pair, giving `()`.

Tests: `RunestoneTests/CharacterPairTests` (insert the pair, skip over an existing closer, wrap a
selection, don't double-close), and EditorKit's `EditorErgonomicsTests` for the same through the app's
editor.

Still open if wanted: insert the pair only when it "closes something" (not before a word character)
and never inside a string it would break, and a Settings switch to turn auto-close off (the app sets
`characterPairs` unconditionally today).


# Editor engine tickets (`omnie-dev-editor-engine`)

Changes that belong in the engine fork, not in the app. Each is justified with numbers or a spec
measured from this repo, and each has an app-side plan.

**Status:** all three landed, each with engine tests: #3 (auto-close) in **0.6.10**, #2 (fold-all cost)
in **0.6.11**, and #1 (multi-selection) in **0.7.0** — the public API change `packages/EditorKit/Package.swift`'s
`exact:` version now pins.

---

## 1. Multi-selection (for ⌘D, Select next occurrence) — landed

**Before.** The engine exposed zero-length cursors only (`textView.additionalCaretLocations`), so a
second ⌘D press added a *cursor* at the next occurrence and typing **inserted** there instead of
**replacing** it, with no per-occurrence highlight. ⇧⌘L worked around it by deleting the word and
leaving a cursor at each site.

**Landed (patch 0019, `omnie-dev-editor-engine` 0.7.0).**

```swift
// Runestone TextView
public var selections: [NSRange] { get set }   // the primary first; length 0 is a caret
```

- Every selection has a length and moves with edits; setting them sends **one** selection-change
  notification.
- Typing and backspace apply at all of them right to left in **one undo group**, leaving a caret after
  each change.
- Secondary selections are drawn as a highlight (`Decoration.Style.selection`); a zero-length one is
  still a caret.
- `additionalCaretLocations` remains, as the carets among the selections, so the caret-only path
  (patch 0012) keeps working.

**App side.** `WorkspaceModel.selectNextOccurrence` adds the next occurrence as a real selection
(typing replaces every one in a single undo step); `changeAllOccurrences` (⇧⌘L) selects them all
instead of deleting the word; Esc, a tap or an arrow collapses to one.

**Tests.** `RunestoneTests/MultiSelectionTests` (7: replace every selection, backspace, one undo,
carets, merging overlaps, ordinary edits moving them, one notification), `MultiCursorTests` still
pass, and `EditorErgonomicsUITests.testSelectNextOccurrenceThenTypingReplacesEveryOne` end to end.

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


# Editor engine tickets (`omnie-dev-editor-engine`)

Two changes belong in the engine fork, not in the app. Both are justified with numbers or a spec
measured from this repo, and both have an app-side plan ready. Bump the engine to **0.7.0** and set
`packages/EditorKit/Package.swift`'s `exact:` version when they land.

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

## 2. Fold-all layout cost

**Measured** by `EditorKitTests/PerformanceTests` on a ~0.8 M-character, 20 000-line file with
~2 000 foldable blocks:

| Step | iPad Pro simulator | CI runner |
|---|---|---|
| Build the fold ranges (app) | 0.18 ms | — |
| `textView.foldedRanges = ranges` (engine) | **0.87 s** | **8.0 s** |

Building the ranges is free; **hiding them is the whole cost**. It looks like the setter invalidates
layout per range rather than once.

**Ask.** Make hiding many ranges cheap:
- Collect the ranges, then invalidate layout **once**; or
- Store folds as a set/mark and skip regenerate-layout for rows that are already hidden; or
- Report the fold count so a caller can chunk a large `foldAll` (a 2 000-block file is ordinary).

**App side.** No change — `CodeEditorController.foldAll()` already sets every range in one call.

**Tests.** Add an engine test that hides N ranges and asserts a single layout pass (e.g., count
`layoutSubviews`/invalidations), so the cost can't regress silently.

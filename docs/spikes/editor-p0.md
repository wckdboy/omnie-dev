# P0 spike: editor engine (PLAN §5.1.5)

**Status: in progress. Simulator numbers only; the decision needs a release build on the 13" iPad Pro M5.**

## Setup

- **Engine:** `omnie-dev-editor-engine` 0.6.1, a hard fork of Runestone 0.5.2 with patches 0001–0008 (see its `PATCHES.md`): no private API, the #413 fix, tree-sitter 0.26.13, three scroll-performance fixes found by profiling, the reparse moved off the main thread, and a settable `inputView`.
- **Grammars:** LangKit vendors JavaScript, TypeScript/TSX, JSON, Python, Swift, CSS and HTML (ABI 14–15) from hash-pinned releases.
- **Harness:** `apps/ipad/Sources/Spike/EditorSpike.swift`. Run it from the palette ("Run editor spike (P0)") or with the launch argument `-OmnieRunCommand spike.editor`. Optional filters: `-OmnieSpikeEngine omnie|omnie-plain|textkit`, `-OmnieSpikeTests 1,2,3,4`. Results are written as JSON to Documents (Files › On My iPad › Omnie-dev).
- **Variants:**
  - **omnie:** the engine with TypeScript highlighting.
  - **omnie-plain:** the same engine with no language, which separates the engine's cost from tree-sitter's.
  - **textkit:** a plain `UITextView`, the TextKit 2 baseline. It has **no syntax highlighting**, so it isn't an equal comparison.
- **Fixtures:** 100,000 lines (2.7 MB) of generated TypeScript, and one 20,000-character minified line.
- **Scroll test:** "fling" moves at 8,000 pt/s (about the top speed of an iOS fling) for 3 s down and 3 s up, and is pass/fail. "Indicator drag" sweeps the whole file in 4 s and is recorded for comparison only.

## Simulator results (release build, iPad Pro 13" M5 simulator, iOS 26.1, 9 Oct 2026)

The simulator renders at 60 Hz on the Mac's GPU and has none of the device's memory limits. These numbers check the harness and show relative costs. They don't decide the spike.

| Test (target) | omnie | omnie-plain | textkit |
|---|---|---|---|
| 1 open 100k lines (≤ 300 ms, ≤ 150 MB) | ❌ 384 ms, 154 MB | ✅ 108 ms, 33 MB | ✅ 37 ms, 3 MB |
| 2 fling, wrap off (< 5 ms/s hitch, no scroller jumps) | ❌ 18 ms/s | ❌ 14 ms/s | ✅ 0 ms/s, but document height changed 175× |
| 2 fling, wrap on | ❌ 20 ms/s | ❌ 13 ms/s | ✅ 0 ms/s, height changed 175× |
| 2 indicator drag (info) | 252–262 ms/s | 36–104 ms/s | 88–92 ms/s, height changed ~135× |
| 3 type 200 chars, no on-screen keyboard (p95 ≤ 4 ms) | ❌ 7.2 ms | ❌ 6.8 ms | ❌ 9.9 ms (max 94 ms) |
| 3 type 200 chars, on-screen keyboard (info) | 12.2 ms | 10.9 ms | 10.1 ms (max 93 ms) |
| 4 one 20k-char line (no stall > 100 ms) | ✅ 1 ms | ✅ 1 ms | ✅ 19 ms |
| 11 static check: no private API | ✅ none in the engine (patch 0001) | | |

**Before patches 0004–0006**, fling was 81 ms/s for omnie-plain and 93 ms/s for omnie, and indicator drag was 484 and 543 ms/s.

## What profiling found

All measurements use Time Profiler on the release build.

1. **Fixed (0004):** a new `DefaultTheme` was built for every line controller and highlighter, and each one loaded asset-catalog colors. That was 4.3 s of 23 s of main-thread time.
2. **Fixed (0005):** line views were removed and re-added (or hidden) as they scrolled, and UIKit's focus and view-visitor bookkeeping ran for each one. The reuse pool was also capped at a quarter of the visible count.
3. **Fixed (0006):** key paths were instantiated at runtime in the red-black tree's position lookups.
4. **Fixed (0007): reparse off the main thread.** Every keystroke used to re-parse with tree-sitter and compute changed ranges on the main thread, about 12 ms of each 28 ms keystroke. With the reparse on a background queue, highlighted typing costs the same as plain typing.
5. **Measured: the on-screen keyboard.** With the software keyboard showing, about three quarters of each keystroke was UIKit updating the keyboard's keyplane, assistant bar and constraints on every selection change. That's why test 3 now runs twice: "no on-screen keyboard" (as with a Magic Keyboard, the primary input) is pass/fail, and the on-screen run is for information. Without the keyboard the engine types faster than `UITextView`. What's left is about 4 ms of `replaceText` and layout per keystroke.
6. **Open: opening a highlighted file** costs about 120 MB more and 280 ms more than plain. Memory is in the tree-sitter tree and the highlight state; needs investigation.
7. **Observed: TextKit 2's height estimates.** `UITextView` changed its document height 135–175 times in one scroll pass, the instability the plan describes (§5.1). My scroller-jump heuristic didn't flag a visible jump; that needs checking by eye on the device.

## Still to run (needs the device or hands)

- Tests 1–4 in a **release build on the iPad**: this is the decision.
- Tests 5–8: IME (Japanese, Chinese, Korean, emoji ZWJ, dictation), Scribble with Pencil Pro, hardware keyboard, VoiceOver.
- Tests 9–10: the decoration load and the 50-caret multi-cursor prototype. Neither layer exists yet.

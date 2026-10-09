# P0 spike: editor engine (PLAN §5.1.5)

**Status (9 Oct 2026): measured on the device. Tests 1, 2, 4 and 11 pass. Test 3 (typing) misses by about 1 ms at p95. Tests 5–10 not yet run.**

## Device results: iPad Pro 13" M5 (iPad17,4), iPadOS 27.0, release build, engine 0.6.2

Raw results: `results/ipad-pro-13-m5-engine-0.6.2-*.json` (and the earlier 0.6.1 run next to it).

| Test (target) | Engine + TS highlighting | Engine, plain | UITextView (TextKit 2, no highlighting) |
|---|---|---|---|
| 1 open 100k lines (first paint ≤ 300 ms, ≤ 150 MB) | ✅ text in **108 ms**, highlighted at 266 ms, **136 MB** peak | ✅ 102 ms, 15 MB | ✅ 55 ms, 4 MB |
| 2 fling, wrap off / on (< 5 ms/s hitch, no scroller jumps) | ✅ **0 hitches**, every frame 8.3 ms (120 Hz) | ✅ 0 | ✅ 0–1.5 ms/s, but document height changed **353×** per pass |
| 2 indicator drag, whole file in 4 s (info) | **0 hitches**, 8.3 ms frames | 0 | 10 ms/s, frames up to 35 ms, height changed ~230× |
| 3 type 200 chars mid-file, no on-screen keyboard (p95 ≤ 4 ms) | ❌ **4.2–5.1 ms** over 5 runs (p50 2.9–3.5), worst keystroke **5.2–5.7 ms** | ❌ 5.6 ms | ✅ 2.0–2.1 ms p95, but worst keystroke **78–122 ms** |
| 3 same, on-screen keyboard (info) | 8.2 ms | 7.5 ms | 3.7 ms (worst 51–53 ms) |
| 4 one 20k-char line (no stall > 100 ms) | ✅ 1 ms | ✅ 1 ms | ✅ 22 ms |
| 11 no private API | ✅ | | |

**Reading it:**
- Scrolling, the reason §5.1 chose Core Text, is perfect on the device: not one dropped frame at 120 Hz, even dragging through all 100k lines in 4 s. TextKit 2's height estimates changed hundreds of times per pass, which is exactly the instability §5.1 cites.
- Typing is close but not passing. The p95 is about 1 ms over, while the worst keystroke is 5.7 ms against TextKit's 78–122 ms stalls; for the feel of typing, the tail is arguably what matters. What's left is per-keystroke layout and Swift reference counting in Runestone's line tree (weak parent pointers force slow-path refcounting).
- By §5.1.6 the engine isn't locked yet. The fallback for a performance miss is "profile first", and the miss is narrow and localized.

## Simulator setup and history

The rest of this document is the simulator work that led to the patches.

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

## Simulator results (release build, iPad Pro 13" M5 simulator, iOS 26.1, engine 0.6.1)

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

## Still to run

- Test 3: get the p95 under 4 ms. Candidates: the line tree's weak parent references (slow-path refcounting on every node), and per-keystroke layout of all visible lines.
- Tests 5–8 (needs hands on the iPad): IME (Japanese, Chinese, Korean, emoji ZWJ, dictation), Scribble with Pencil Pro, hardware keyboard, VoiceOver.
- Tests 9–10: the decoration load and the 50-caret multi-cursor prototype. Neither layer exists yet.

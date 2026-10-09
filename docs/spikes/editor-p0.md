# P0 spike: editor engine (PLAN §5.1.5)

**Status (9 Oct 2026, engine 0.6.5): every automated test passes on the iPad (1, 2, 3, 4, 9, 10, 11). The decision now waits only on the hands-on tests 5–8 (IME, Scribble, hardware keyboard, VoiceOver).** Patch 0013 changed how selection changes are announced to the input system, so IME and shift-selection (tests 5 and 7) are the ones to watch.

## Device results, engine 0.6.5 (iPad Pro 13" M5, iPadOS 27.0, release build)

Raw results: `results/ipad-pro-13-m5-engine-0.6.5-*.json`.

| Test (target) | Engine + TS highlighting | Engine, plain | UITextView (no highlighting) |
|---|---|---|---|
| 1 open 100k lines (≤ 300 ms, ≤ 150 MB) | ✅ 102 ms, highlighted at 262 ms, 135 MB | ✅ 88 ms, 22 MB | ✅ 58 ms, 7 MB |
| 2 fling, wrap off/on (< 5 ms/s, no jumps) | ✅ 0, every frame 8.3 ms | ✅ 0 | ✅ 0, document height changed 353× |
| 2 indicator drag (info) | 0 | 0 | 9.6–9.9 ms/s, frames to 35 ms |
| 3 typing p95, no on-screen keyboard (≤ 4 ms) | ✅ **0.5 ms**, worst 3.0 | ✅ 0.4 ms | ❌ 4.2 ms, worst 54 ms |
| 3 typing, on-screen keyboard (info) | 0.4 ms | 0.4 ms | 1.4 ms, worst 79 ms |
| 4 one 20k-char line (no stall > 100 ms) | ✅ 1 ms | ✅ 1 ms | ✅ 21 ms |
| 9 decoration load: 500 diagnostics + 50 agent hunks | ✅ fling 0 hitches, typing 0.5 ms, setting marks 0.4 ms | | |
| 10 multi-cursor, 50 carets (≤ 8.3 ms, IME on primary) | ✅ 3.0 ms p95, all lines correct | | |
| 11 no private API | ✅ | | |

Not yet built: ghost text (part of test 9's load) and mirroring committed IME text to secondary carets (test 10 prototype limit).

## Hands-on checklist (tests 5–8, on the iPad, Omnie-dev with a code file open)

**Automated parts (9 Oct 2026).** `apps/ipad/UITests` (scheme OmnieDev, `xcodebuild test`) covers what a machine can drive, passing twice in a row on the iPad simulator:

- **7 Hardware keyboard:** real key events: arrows, ⌘←/⌘→/⌘↑/⌘↓, ⌥←/⌥→, ⌥⇧ word selection then ⇧→ to shrink it and typing over it, ⌘Z/⇧⌘Z, ⇧⌘→ + ⌘C, ⌘V, ⌘A then typing. All behave like `UITextView` (⌥← skips punctuation such as `= ` the way UIKit does). Under XCUITest the first ⌘ shortcut after a tap is dropped in a stock `UITextView` too, so the tests send a harmless one first; it isn't an editor bug.
- **8 VoiceOver:** the editor is one element named "Code editor, main.ts" whose value is "Line 1, column 1. let alpha = 1;". Apple's accessibility audit of the main screen passes after fixing what it found: chrome text now follows Dynamic Type (PLAN §883; the fixed 9–17 pt sizes became the matching text styles), the agent status dot is a 44 pt target, and file names are announced as "main.ts, file" / "main.ts, tab". Accepted and printed: the gutter's line numbers follow the editor's code size, which is separate from Dynamic Type by design, and the one-line status strip truncates at the largest accessibility sizes.
- **On the iPad itself** the same tests need Settings › Developer › Enable UI Automation (they stop at "Timed out while enabling automation mode" without it).

Still by hand: 5 (real keyboards' candidate windows, dictation), 6 (Scribble), and in 8 the Diagnostics rotor and listening to the speech.

- **5 IME:** Japanese kana→kanji, Chinese pinyin, Korean (including ㅇ+ㅓ→어), an emoji ZWJ sequence (👩‍💻), dictation. Text lands where the caret was; candidates and marked text look right.
- **6 Scribble (Pencil Pro):** write into an empty line, between two tokens, scratch-out to delete, circle to select.
- **7 Hardware keyboard:** arrows, ⌥/⌘ + arrows, shift-selection, ⌥⇧ word selection followed by ⇧ arrows, ⌘Z/⇧⌘Z, ⌘A/⌘C/⌘V.
- **8 VoiceOver:** the editor reads its name and "Line N, column M"; swipe by character/word/line; the Diagnostics rotor jumps between marks (try `-OmnieDemoMarks` in a debug build).

## Earlier device results (engine 0.6.2)



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

## After engine 0.6.4 (simulator, release build; device run pending)

Engine 0.6.4 adds patch 0013: Runestone kept re-announcing the selection to the input system on every layout pass once any caret placement had set a flag, so every keystroke made UIKit's keyboard state re-tokenize the surrounding sentence with ICU. That was most of the per-keystroke cost all along, which is why earlier layout fixes moved typing so little. It now announces once.

| Test | Result (simulator) |
|---|---|
| 3 typing, no on-screen keyboard (p95 ≤ 4 ms) | ✅ **0.8 ms** (was 7.1), worst 4.5 ms |
| 3 typing, on-screen keyboard (info) | 0.8 ms (was 11.7) |
| 9 decoration load: 500 diagnostics + 50 agent hunks, then fling and typing | setting 600 marks: 0.9 ms; fling and typing unchanged from undecorated runs (device decides fling) |
| 10 multi-cursor, 50 carets (typing within 8.3 ms, IME on the primary caret) | ✅ **5.9 ms** p95, every line correct, IME marked text on the primary caret only |

**Patch 0013 touches IME behavior.** Tests 5–7 on the device (Korean, Japanese and Chinese input, Scribble, shift and option-shift selection) are the check that it didn't break multi-stage input.

**Not built yet:** ghost text (test 9's third load), and mirroring committed IME text to secondary carets (test 10 prototype limit).

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

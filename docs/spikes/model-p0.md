# P0 spike 2: local 7B model on the iPad (PLAN §7, §20)

**Status (9 Oct 2026): measured on the device. The plan's estimates hold or are beaten; the 7B is viable as the offline agent model.**

## Setup

- **Device:** iPad Pro 13" M5 (iPad17,4), **11.2 GB physical RAM** (the 12 GB model), iPadOS 27.0, release build.
- **Model:** `mlx-community/Qwen2.5-Coder-7B-Instruct-4bit`, 4.28 GB of weights, SHA-256 `56a3d947…26060e` (matches Hugging Face). Copied into the app's Documents over USB (2 min 12 s).
- **Runtime:** MLX Swift 0.32.3 through `mlx-swift-lm` 3.32.3 (`MLXLLM`), tokenizer from `swift-transformers` 1.3.4, loaded from a local folder (no downloader).
- **Entitlements:** `increased-memory-limit` and `extended-virtual-addressing`, on an explicit App ID.
- **Harness:** `apps/ipad/Sources/Spike/ModelSpike.swift`, palette command "Run model spike (P0)" or `-OmnieRunCommand spike.model`. One 8-token warm-up first (it compiles GPU kernels), then a code prompt at 1k, 4k and 8k tokens, 128 tokens decoded each, greedy.
- **Raw results:** `results/ipad-pro-13-m5-qwen2.5-coder-7b-4bit-*.json`.

## Results

| | Measured | PLAN estimate |
|---|---|---|
| Memory the app may use before loading (`os_proc_available_memory`, with the entitlement) | **12.3 GB** | "~6.5 to 7.5 GB usable working set" |
| Load (memory-mapped safetensors) | **0.7 s**; footprint +4.1 GB | — |
| Decode | **30.5 / 28.2 / 26.2 tok/s** at 1k / 4k / 8k context | 20–40 tok/s |
| Prefill | **792 / 773 / 653 tok/s** | 150–400 tok/s |
| Time to first token | **1.3 s** (1k), **5.2 s** (4k), **12.3 s** (8k) | "15–40 s" for a 6k prompt |
| App footprint at 8k context | **5.4 GB**, with 6.9 GB still available | 5–6.5 GB during an agent turn |

A cold first generation (no warm-up) ran prefill at 323 tok/s and took 3.1 s for 1k tokens; the app should warm the model up once after loading.

## What it means for the plan

- **The 7B fits with room to spare on a 12 GB iPad.** Peak 5.4 GB at 8k context, against a 12.3 GB per-app limit. Web views (runner, preview, Stage) live in separate processes and add system pressure, so the release order in §20 still matters, but the "one resident large model" rule has margin.
- **8k context is usable** (12 s to first token from cold context). With prefix caching of the system prompt and tool schema (§7), follow-up steps in an agent turn only prefill what changed.
- **Decode at ~28 tok/s** is fast enough to stream plans and patches comfortably.

## Not measured yet

- Thermal behavior over a long session (sustained decode for 10+ minutes), and battery cost.
- The Tiny FIM model (0.5–1.5B) for ghost text, and running Tiny and 7B together.
- Coexistence with the editor, a preview web view and the Stage under memory pressure (the §20 soak test).
- llama.cpp (GGUF) as the fallback path.

## Tiny pack through ModelKit (9 Oct 2026, iPad Pro 13" M5, debug build)

The first real use of the local model in the app: Settings › Models downloads the pinned pack, and the commit sheet's "Draft with local model" writes the subject line. `-OmnieModelSmoke` (debug builds) runs the whole path:

| Step | Result |
|---|---|
| Download and SHA-256 check, Qwen2.5-Coder-0.5B-Instruct-4bit (290 MB, from Hugging Face) | 17.3 s |
| Load | 0.58 s |
| Fill-in-the-middle, 24 tokens max (`return |` in a Swift fibonacci) | 0.88 s: `fibonacci(n - 1) + fibonacci(n - 2)`, then the model kept going; `FIM.trim` cuts at the suffix |
| Commit draft from a README change | 0.19 s: "Improve README.md for better network control" (template: "Update README.md") |

Qwen's FIM special tokens tokenize correctly through swift-transformers, so the instruct model can serve ghost text. Within the plan's 300 ms ghost-text budget only for short completions; ghost text should ask for a single line.

**Ghost text (same run):** typing `return ` at the end of a line in a Swift fibonacci, the suggestion `fibonacci(n - 1) + fibonacci(n - 2)` appeared **454 ms after the last keystroke**: the 300 ms idle pause plus ~150 ms in the model (single line, warm; the first FIM after load also compiles kernels, 0.88 s). Tab inserted it. Against the §16 budget ("≤ 300 ms after an idle pause") that's ~150 ms after the pause, inside the target. Ghost text is offered only at the end of a line, single-line, and is cleared by any edit or caret move.

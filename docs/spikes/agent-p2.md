# Agent on the device: first runs (P2, 9 Oct 2026)

The full loop on the iPad Pro 13" M5 (debug build): an agent task branches `agent/<slug>` into its own worktree, runs Qwen2.5-Coder-7B-Instruct-4bit through MLX with AgentKit's typed tools, every call checked by PolicyKit, the journal written at every step, and ends in a changeset for review (squash merge on accept). Started with `-OmnieOpenFolder Projects/agent-demo -OmnieAgentTask "<goal>"` (debug builds).

## What it took to get calls through

1. **mlx-swift-lm parses tool calls itself.** Given no tool list, it rejected every `<tool_call>` as undeclared, so the agent saw empty replies. The backend now passes the tool schemas to the generator (not to the chat template; the system prompt already lists them) and turns parsed calls back into Qwen's `<tool_call>` text, so AgentKit stays model-agnostic.
2. **Tool results as `<tool_response>` user turns**, the exact text Qwen's template produces, instead of relying on how the template renders the `tool` role.
3. **Constrained retry.** After some tool results, greedy decoding's first token was `<|im_start|>`, then the turn ended. When a reply has no call, the step is retried with the reply pre-started as `<tool_call>\n{"name": "` (PLAN §7: "constrained JSON decoding plus retry for local models"). The first attempt stays free so the model can still write its plan.

## Golden task 1: "Add a farewell function to src/greet.ts that returns Goodbye, name! and use it in src/index.ts"

| | |
|---|---|
| Mechanics | ✅ 6 steps: list, read, patch, read, patch, finish. No malformed calls after the retry; patches applied against the right blob shas |
| Result | ❌ It changed `greet`'s string to "Goodbye" instead of adding `farewell`, added a second `greet(...)` call, and summarized the task as done |

This is the case changeset review is for: nothing lands until you accept. It also says the plan's P2 bar (a golden task set at an agreed pass rate) needs an evaluation harness and prompt work before the local 7B is trusted with multi-step edits. Next steps: a golden task suite run on the device, a read-back step before finish (the agent rereads what it changed), and checking whether a short "plan first" turn improves the 7B's edits.

## Golden task set on the device

`AgentKit.GoldenTask` holds five tasks with fixtures and outcome checks (farewell: add a function and use it; rename across files; fix-add: fix a bug; constants: create a file; readme: add a doc section). The checks are unit-tested: each fixture fails unsolved and passes when solved correctly. `-OmnieAgentEval <label>` (debug builds) runs them against the local 7B in fresh folders, prints failing transcripts, and saves JSON to Documents.

| Run | Pass | What changed |
|---|---|---|
| baseline | 2/5 (fix-add, constants) | — |
| v2 | 3/5 (+readme) | `read` no longer shows a phantom empty last line; `patch` tolerates blank lines at the edges of find; a repeated failing call gets a hint; the first finish shows the changed files and asks for a check; `append_to_file`; clearer stale-sha message; the eval journal moved out of the project (grep found it) |
| v3 | 3/5 | the parser takes the JSON object inside `<tool_call>` even with stray fences; `patch` refuses a replace that would duplicate the lines after find (the rename failure); a system-prompt rule to add code rather than rewrite |
| v4 | **4/5 (+rename)**, 257 s for all five | `grep` matches text or a regex (the model searched `total\(`); `patch` falls back to matching lines ignoring blank lines and indentation when that match is unique |

Every fix was in the tools or the loop, found by reading the failing transcripts; the model is unchanged (Qwen2.5-Coder-7B-Instruct-4bit, greedy). Still failing: **farewell** — the model's first move is always to rewrite `greet`'s return line to "Goodbye" (greedy decoding makes it deterministic), and it doesn't recover in 12 steps. Rename passes on its files but hit the step cap instead of finishing. Five tasks are a smoke test, not the "agreed pass rate" the plan asks for; the set should grow to 20–30 before anyone agrees on a number.

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

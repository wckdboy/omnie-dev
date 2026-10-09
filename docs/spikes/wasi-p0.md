# P0 spike 3: WASI in WKWebView (PLAN §8, §25)

**Follow-up (P3, 9 Oct 2026):** RunKit now has its own preview1 layer (`packages/RunKit/Sources/RunKit/JS/runtime/wasi-worker.js`) over the real project, as decided below. The same suite passes **73 of 73** on the iPad (6.1 s) and on the Mac; `-OmnieWasiConformance` runs it on the device, `WasiConformanceTests` on the Mac. Fuel is still to build; the memory cap is checked at every system call.

**Status (9 Oct 2026): go.** wasm32-wasip1 programs run in Omnie-dev's own `WKWebView` on the iPad Pro 13" M5 (iPadOS 27.0, release build), each in its own Worker. A timeout kills a runaway module. Every failure in the suite comes from the JS shim (browser_wasi_shim 0.4.2), not from WebKit: Node/V8 fails the same 18 tests with the same messages. RunKit needs its own preview1 layer where the shim falls short, and fuel and memory caps are still to build.

Harness: `apps/ipad/Sources/Spike/WASISpike.swift` and `apps/ipad/Resources/WASISpikeApp/` ("Run WASI spike (P0)" or `-OmnieRunCommand spike.wasi`). Inputs come from `scripts/vendor-wasi-spike.py` (gitignored output). Raw result: `results/ipad-pro-13-m5-wasi-2026-10-09.json`.

## Setup

- **Suite:** [WebAssembly/wasi-testsuite](https://github.com/WebAssembly/wasi-testsuite) at `e0aa527` (branch `prod/testsuite-base`), the prebuilt wasm32-wasip1 tests for C, Rust and AssemblyScript (72 tests). Each test's `.json` gives args, env, preopened dirs, and the expected exit code, stdout and stderr, which the runner compares.
- **Runtime:** `@bjorn3/browser_wasi_shim` 0.4.2 (MIT OR Apache-2.0, hash-pinned), with an in-memory filesystem built from the test's directory and preopened as `/`, as the official runner does.
- **Isolation:** each test runs in its own module Worker inside the web view's WebContent process. The runner terminates the Worker on a timeout (10 s, or 2 s for the timeout test).
- **Timeout test:** a hand-written module whose `_start` is `loop { br 0 }`.
- **Serving:** a `WKURLSchemeHandler` for `omnie-wasi://` serves the bundled files with `application/wasm` and `text/javascript` MIME types, plus COOP/COEP headers.

## Results (device; the simulator and Node give identical pass/fail)

| | Result |
|---|---|
| Suite | **55 of 73 pass**: AssemblyScript 12/12, C 11/14, Rust 31/46, timeout 1/1 |
| Timeout | ✅ the infinite loop is terminated at 2.0 s; the next test runs normally |
| Speed | the whole suite takes 2.3 s; a test takes 3–9 ms including compile and instantiate |
| `omnie-wasi://` origin | ✅ **a secure context.** This settles the open question in `webgpu-p0.md`: Stage can serve bundled three.js from a custom scheme and still get WebGPU |
| Cross-origin isolation | ✅ `crossOriginIsolated` is true with COOP `same-origin` and COEP `require-corp` from the scheme handler |
| Shared memory | ✅ `new WebAssembly.Memory({shared: true})` works and its buffer is a `SharedArrayBuffer`, although the `SharedArrayBuffer` global isn't exposed. That's enough for wasi-threads |

**What fails, and why (all in the shim):**

| Area | Tests | Shim behavior |
|---|---|---|
| Symlinks | nofollow_errors, path_exists, readlink, symlink_create, symlink_filestat, path_symlink_trailing_slashes | `path_symlink` returns `NOTSUP` |
| Append mode | c/pwrite-with-append, fd_flags_set | `O_APPEND` / `fdflags` not honored |
| Timestamps | fd_filestat_set, path_filestat, fstflags_validate | `*_set_times` unsupported or wrong; `attempt to subtract with overflow` |
| Rights | path_open_preopen, path_open_read_write | preview1 rights aren't modeled |
| Hard links | path_link | linking onto an existing path succeeds |
| Renames | path_rename_dir_trailing_slashes | trailing slash on a directory rename gives `NOENT` |
| Polling | poll_oneoff_stdio | `poll_oneoff` returns `NOTSUP` |
| Sockets | c/sock_shutdown-* | none, by design (PLAN §25 L1: no sockets by default) |

## Decision and implications for RunKit (P3)

- **Go:** WASI preview1 in WKWebView is the on-device runtime, as §8 planned. JavaScriptCore runs the modules correctly; correctness is down to the WASI layer.
- **Own the WASI layer.** RunKit needs a preview1 implementation backed by the real project directory through the Swift bridge, not an in-memory tree. Either fork browser_wasi_shim (filling the gaps above: symlinks, append, times, rights, poll) or write one. The suite above is the conformance gate (§26.1), now automated.
- **Timeouts work** through Worker termination. **Fuel** (deterministic instruction budgets) isn't built. Planned approach: instrument the module at load time with a counter decremented in every loop and function prologue, trapping at zero. **Memory caps:** reject modules whose memory maximum is above the policy, or none, before instantiating.
- **Threads are possible:** cross-origin isolation works on the custom scheme and shared wasm memory is available.
- **Stage (§13)** can use a custom scheme handler instead of an `https` base URL, since it's a secure context.

## Not covered

- CPU-heavy workloads (near-native speed claim in §8): these tests are functional and tiny. Measure in P3 with real tools (e.g. a wasm build of `jq` or `ripgrep`).
- A wasm escape attempt beyond the preopen (§26.1 "escape attempts"): with the in-memory tree there's nothing outside to reach. This belongs with the real filesystem bridge.

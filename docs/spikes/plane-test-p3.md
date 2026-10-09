# P3 exit test: the plane test (PLAN §22)

**Status (9 Oct 2026): passes on the iPad Pro 13" M5 (iPadOS 27, debug build), 67–70 s end to end, three runs.**

PLAN's bar for P3: *a Vite-style three.js project goes from clone to agent feature to tests to Stage to commit to queued push, all offline.* `scripts/plane-test.sh <device id>` runs it unattended on a connected iPad; the driver is `apps/ipad/Sources/Spike/PlaneTest.swift` (`-OmniePlaneTest`).

## The project

`fixtures/plane-demo`: `index.html` loading `src/main.ts` (three.js, Vite-style), a scene in `src/scene.ts`, a Stage module `src/planets.stage.ts`, and vitest tests for `orbitPosition`, which has its sine and cosine swapped. `package.json` asks for `three`.

The "remote" is a bare repository copied into the app's Documents, so the test never touches the network or a real server.

## Steps and results (last run)

| Step | Where | Result |
|---|---|---|
| Clone | online | 1 s, through GitKit |
| Prepare for offline | online | `three@0.186.1` into the npm cache (already cached on later runs) |
| Tests before the fix | plane mode | 2 failing |
| Agent: "fix orbitPosition so the tests pass" | plane mode, local Qwen2.5-Coder 7B (4-bit) | review in 64 s, one file changed; merged with an `Assisted-by` trailer |
| Tests | plane mode | 2/2 pass |
| Type check | plane mode | no errors (198 ms) |
| Preview (`index.html` + `main.ts`, three from the cache) | plane mode | renders, no console errors |
| Stage (`planets.stage.ts`) | plane mode | 3 objects, 63 fps |
| Commit (a README edit) | plane mode | made |
| Sync | plane mode | push queued ("Queued, sends when online") |
| Plane mode off | online | queued push sent; the remote's `main` equals local `HEAD` (also checked with `git log` on the Mac) |

## What it found and fixed

- **Sync in plane mode was refused, not queued.** The policy engine denies network actions in plane mode, and the push was being authorized as if it happened now. A queued push is authorized "for later" (still Face ID, still audited); it's sent only once plane mode is off and the network is back.
- **TypeScript Stage modules failed the type check** (`({ scene, onFrame })` had no type). The checker now declares a global `OmnieStage` type; scene modules write `export default ({ scene, onFrame }: OmnieStage) => …`.
- **Agent commit subjects were cut mid-sentence.** A long summary now gets "…" in the subject and the whole summary in the body.

## Notes

- Approval prompts (Face ID for the push) are answered by `-OmnieTestApprove`, which exists only in debug builds; decisions are still written to the audit log.
- The agent's fix is correct but not minimal (it added a `y: 0` field and dropped the return type annotation); the tests and type check accept it.

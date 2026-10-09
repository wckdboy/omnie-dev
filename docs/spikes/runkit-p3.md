# RunKit, Preview and Stage on the device (P3, 9 Oct 2026)

iPad Pro 13" M5, iPadOS 27, debug build. Checked with `-OmnieTerminal`, `-OmniePreview` and `-OmnieStage` (debug launch arguments) on small demo projects.

| | Result |
|---|---|
| Python script (Pyodide start + run) | 0.88 s from the command to the output |
| Python tests (pytest subset, 3 cases) | 0.77 s, failures with values |
| JS/TS tests (vitest subset) | about 0.5 s in the simulator; same code path |
| Preview of a three.js page (`import * as THREE from "three"`, offline) | loads, TypeScript transpiled on the fly |
| Stage, a 4,212-triangle GLB | 60 fps steady, 17–18 ms worst frame after a 248 ms first frame (shader warm-up) |

**Finding: 60 fps, not 120.** The display runs at 120 Hz, but WKWebView paces `requestAnimationFrame` at 60 Hz, and there's no public API to raise it (Safari exposes it only as a feature flag). PLAN §16's "120 fps for light scenes" isn't reachable in a third-party web view today; 60 fps holds for the Stage and previews. Revisit when WebKit offers a setting.

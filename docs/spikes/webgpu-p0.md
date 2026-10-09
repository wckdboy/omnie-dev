# P0 spike 4: WebGPU and WebGL2 in a third-party WKWebView (PLAN §13 Stage, Appendix A)

**Status (9 Oct 2026): both work on the iPad Pro 13" M5, iPadOS 27.0, release build, in Omnie-dev's own `WKWebView`.**

Harness: `apps/ipad/Sources/Spike/WebGPUSpike.swift` ("Run WebGPU spike (P0)" or `-OmnieRunCommand spike.webgpu`). Raw result: `results/ipad-pro-13-m5-webgpu-spike-*.json`.

| | Result |
|---|---|
| `navigator.gpu` | ✅ present, **only in a secure context**. With `loadHTMLString(_:baseURL: nil)` the page has an opaque origin and `navigator.gpu` is undefined; with an `https` base URL it's there |
| Adapter / device | ✅ Apple GPU (`vendor: apple`) |
| Features | `shader-f16`, `timestamp-query`, `float32-filterable`, `float32-blendable`, ASTC/BC/ETC2 (including sliced 3D), `bgra8unorm-storage`, `depth32float-stencil8`, `primitive-index`, `clip-distances`, texture formats tier 1 and 2 |
| Limits | `maxBufferSize` and `maxStorageBufferBindingSize` 1 GB, `maxComputeWorkgroupSizeX` 1024 |
| WGSL compute | ✅ squared 1M floats, output verified; 96 ms for the first dispatch including pipeline creation and readback |
| WebGL2 | ✅ renders and reads back; `MAX_TEXTURE_SIZE` 16384 |

**Implications for Stage (§13):**
- Stage pages must load from a secure origin: an `https` base URL, or a custom scheme handler serving the bundled three.js (verify a custom scheme counts as secure before relying on it).
- WebGPU can be on by default for scenes that ask for it; WebGL2 stays the fallback.
- The web view reports a desktop-class user agent (iPadOS default), so three.js feature detection, not UA sniffing, should drive renderer choice.

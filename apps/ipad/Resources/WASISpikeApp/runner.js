// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
// P0 spike 3: runs the wasi-testsuite wasm32-wasip1 tests, each in its own module Worker that is
// terminated after a timeout, and compares exit codes and output like the official runner.
const post = (m) => window.webkit.messageHandlers.spike.postMessage(m);
const TIMEOUT_MS = 10_000;
const LOOP_TIMEOUT_MS = 2_000;

function runOne(test) {
  return new Promise((resolve) => {
    const started = performance.now();
    const worker = new Worker("worker.js", { type: "module" });
    const limit = test.expectTimeout ? LOOP_TIMEOUT_MS : TIMEOUT_MS;
    const timer = setTimeout(() => {
      worker.terminate();
      resolve({ timedOut: true, ms: performance.now() - started });
    }, limit);
    worker.onmessage = (e) => {
      clearTimeout(timer);
      worker.terminate();
      resolve({ ...e.data, ms: performance.now() - started });
    };
    worker.onerror = (e) => {
      clearTimeout(timer);
      worker.terminate();
      resolve({ error: String(e.message || e), ms: performance.now() - started });
    };
    const cfg = test.config || {};
    worker.postMessage({
      wasmURL: "../vendor/" + test.wasm,
      name: test.wasm.split("/").pop(),
      args: cfg.args || [],
      env: cfg.env || {},
      rootBase: test.rootBase ? "../vendor/" + test.rootBase : null,
      files: test.files,
    });
  });
}

(async () => {
  const manifest = await (await fetch("../vendor/manifest.json")).json();
  const results = [];
  const t0 = performance.now();
  for (const test of manifest.tests) {
    const r = await runOne(test);
    const cfg = test.config || {};
    let pass, reason = "";
    if (test.expectTimeout) {
      pass = r.timedOut === true;
      reason = pass ? "terminated by timeout" : "did not time out";
    } else if (r.timedOut) {
      pass = false; reason = "timed out";
    } else if (r.error) {
      pass = false; reason = r.error;
    } else {
      const wantCode = cfg.exit_code ?? 0;
      pass = r.exitCode === wantCode;
      if (!pass) reason = `exit ${r.exitCode}, expected ${wantCode}`;
      if (pass && cfg.stdout !== undefined && r.stdout !== cfg.stdout) { pass = false; reason = "stdout differs"; }
      if (pass && cfg.stderr !== undefined && r.stderr !== cfg.stderr) { pass = false; reason = "stderr differs"; }
    }
    const row = { lang: test.lang, name: test.name, pass, reason, ms: Math.round(r.ms) };
    results.push(row);
    post(`${pass ? "PASS" : "FAIL"} ${test.lang}/${test.name} ${row.ms} ms ${reason}`);
  }
  const byLang = {};
  for (const r of results) {
    byLang[r.lang] ??= { pass: 0, total: 0 };
    byLang[r.lang].total++; if (r.pass) byLang[r.lang].pass++;
  }
  post(JSON.stringify({ suiteCommit: manifest.suiteCommit, totalMs: Math.round(performance.now() - t0),
                        passed: results.filter(r => r.pass).length, total: results.length, byLang,
                        // Whether a custom-scheme page is a secure context (WebGPU needs one) and can share memory (WASI threads).
                        page: { origin: location.origin, isSecureContext, crossOriginIsolated,
                                sharedArrayBuffer: typeof SharedArrayBuffer !== "undefined",
                                sharedWasmMemory: (() => { try { return new WebAssembly.Memory({ initial: 1, maximum: 1, shared: true }).buffer.constructor.name; } catch (e) { return String(e); } })() },
                        results }));
})().catch(e => post("runner error: " + e));

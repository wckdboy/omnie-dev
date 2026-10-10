// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
// RunKit's page: runs one script or a set of test files from the project and reports to Swift.
const send = (message) => window.webkit.messageHandlers.run.postMessage(message);

/// Where in the project an error was thrown: the first project frame of its stack, "(src/a.ts:3:9)".
function where(error) {
  const frame = String(error?.stack ?? "").split("\n").map((l) => l.match(/omnie-run:\/\/local\/(?!__omnie\/)([^:?\s)]+)(?:\?[^:\s)]*)?:(\d+):(\d+)/)).find(Boolean);
  return frame ? ` (${frame[1]}:${frame[2]}:${frame[3]})` : "";
}

export function format(value) {
  if (typeof value === "string") return value;
  if (value instanceof Error) return `${value.name}: ${value.message}${where(value)}`;
  try { return JSON.stringify(value) ?? String(value); } catch { return String(value); }
}

for (const level of ["log", "info", "warn", "error", "debug"]) {
  console[level] = (...args) => send({ type: "console", level, text: args.map(format).join(" ") });
}
window.addEventListener("error", (e) => send({ type: "error", text: `${e.message} (${e.filename || "?"}:${e.lineno || "?"})` }));
window.addEventListener("unhandledrejection", (e) => send({ type: "error", text: `Unhandled rejection: ${format(e.reason)}` }));

const params = new URLSearchParams(location.search);
const project = (path) => "omnie-run://local/" + path.split("/").map(encodeURIComponent).join("/");

(async () => {
  try {
    if (params.get("mode") === "wasi") {
      const worker = new Worker("omnie-run://local/__omnie/runtime/wasi-worker.js");
      await new Promise((resolve) => {
        worker.onmessage = (e) => { if (e.data.type === "done") resolve(); else send(e.data); };
        worker.onerror = (e) => { send({ type: "error", text: e.message || "WASI worker failed" }); resolve(); };
        worker.postMessage(JSON.parse(params.get("spec")));
      });
      worker.terminate();
      send({ type: "done" });
    } else if (params.get("mode") === "language" || params.get("mode") === "pylanguage") {
      // Long-lived: Swift sends requests through omnieLanguage(), replies come back as messages.
      const worker = params.get("mode") === "language"
        ? new Worker("omnie-run://local/__omnie/runtime/language-worker.js")
        : new Worker("omnie-run://local/__omnie/runtime/pylanguage-worker.js", { type: "module" });
      worker.onmessage = (e) => send(e.data);
      worker.onerror = (e) => send({ type: "error", text: e.message || "Language service failed" });
      window.omnieLanguage = (request) => worker.postMessage(request);
      send({ type: "ready" });
    } else if (params.get("mode") === "typecheck") {
      const worker = new Worker("omnie-run://local/__omnie/runtime/typecheck-worker.js");
      await new Promise((resolve) => {
        worker.onmessage = (e) => { if (e.data.type === "done") resolve(); else send(e.data); };
        worker.onerror = (e) => { send({ type: "error", text: e.message || "Type checker failed" }); resolve(); };
        worker.postMessage({});
      });
      worker.terminate();
      send({ type: "done" });
    } else if (params.get("mode") === "python" || params.get("mode") === "pytest") {
      // Python runs in a worker, so a runaway script can't freeze the page.
      const worker = new Worker("omnie-run://local/__omnie/runtime/python-worker.js", { type: "module" });
      await new Promise((resolve) => {
        worker.onmessage = (e) => { if (e.data.type === "done") resolve(); else send(e.data); };
        worker.onerror = (e) => { send({ type: "error", text: e.message || "Python worker failed" }); resolve(); };
        worker.postMessage({ mode: params.get("mode"), entry: params.get("entry"), files: params.getAll("file") });
      });
      worker.terminate();
      send({ type: "done" });
    } else if (params.get("mode") === "tests") {
      const runner = await import("omnie-run://local/__omnie/runtime/vitest.js");
      for (const file of params.getAll("file")) {
        runner.__collect(file);
        try { await import(project(file)); }
        catch (e) { send({ type: "test", file, name: "(loading the file)", ok: false, error: format(e), ms: 0 }); }
      }
      await runner.__run(send);
      send({ type: "done" });
    } else {
      await import(project(params.get("entry")));
      send({ type: "done" });
    }
  } catch (e) {
    send({ type: "error", text: format(e) });
    send({ type: "done" });
  }
})();

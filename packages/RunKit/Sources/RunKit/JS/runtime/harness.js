// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
// RunKit's page: runs one script or a set of test files from the project and reports to Swift.
const send = (message) => window.webkit.messageHandlers.run.postMessage(message);

export function format(value) {
  if (typeof value === "string") return value;
  if (value instanceof Error) return `${value.name}: ${value.message}`;
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
    if (params.get("mode") === "tests") {
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

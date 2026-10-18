// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
// RunKit's Python debugger runtime (PLAN.md §5.3): runs a project's Python under python_debugger.py's
// line tracer, in a worker. Stopping is synchronous — the tracer parks on a request the app holds
// open (Debugger.swift) and reads the chosen action back from its response — so the Python frame and
// its locals are still live when the pause is shown.
import { loadPyodide } from "omnie-run://local/__omnie/pyodide/pyodide.mjs";

const base = "omnie-run://local/";
const send = (message) => postMessage(message);
const decode = (path) => base + path.split("/").map(encodeURIComponent).join("/");

self.onmessage = async (event) => {
  const spec = event.data;
  const progress = (text) => postMessage({ type: "progress", text });
  try {
    progress("loading Pyodide");
    const py = await loadPyodide({
      indexURL: base + "__omnie/pyodide/",
      stdout: (text) => send({ type: "console", level: "log", text }),
      stderr: (text) => send({ type: "console", level: "error", text }),
    });
    progress("reading the project files");
    const manifest = await (await fetch(base + "__omnie/manifest.json")).json();
    for (const path of manifest) {
      const data = new Uint8Array(await (await fetch(decode(path))).arrayBuffer());
      py.FS.mkdirTree("/project/" + path.split("/").slice(0, -1).join("/"));
      py.FS.writeFile("/project/" + path, data);
    }
    py.FS.mkdirTree("/omnie");
    py.FS.writeFile("/omnie/python_debugger.py",
                    await (await fetch(base + "__omnie/runtime/python_debugger.py")).text());
    // Packages from the offline cache load as they do in a plain run (uninstrumented: a breakpoint
    // inside a package doesn't stop, but the project's own code around it still steps).
    const packages = await (await fetch(base + "__omnie/python-packages.json")).json();
    const quiet = { messageCallback: () => {}, errorCallback: (text) => send({ type: "console", level: "error", text }) };
    if (packages.lock.length) await py.loadPackage(packages.lock, quiet);
    if (packages.wheels.length) await py.loadPackage(packages.wheels, quiet);
    py.runPython("import os, sys\nos.chdir('/project')\nsys.path[:0] = ['/project', '/omnie']");
    // The tracer blocks here: a synchronous request the app answers with the chosen action.
    const pause = (payload) => {
      const xhr = new XMLHttpRequest();
      xhr.open("POST", base + "__omnie/debug/pause", false);
      xhr.setRequestHeader("Content-Type", "application/json");
      xhr.send(payload);
      return xhr.responseText || "{\"action\":\"continue\"}";
    };
    py.globals.set("omnie_debug_pause", pause);
    py.globals.set("omnie_spec", JSON.stringify(spec));
    py.globals.set("omnie_files_json", JSON.stringify(manifest));
    progress("running");
    await py.runPythonAsync(`
import json, python_debugger
python_debugger.run(json.loads(omnie_spec), omnie_debug_pause, json.loads(omnie_files_json))
`).catch((e) => send({ type: "error", text: String(e.message || e).split("\n").filter(Boolean).pop() }));
  } catch (e) {
    send({ type: "error", text: String(e.message || e) });
  }
  send({ type: "done" });
};

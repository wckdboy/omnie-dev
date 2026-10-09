// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
// Runs Python with Pyodide (CPython in WebAssembly) in a worker: the project's files are copied
// into Pyodide's in-memory file system, then a script or the tests run there.
import { loadPyodide } from "omnie-run://local/__omnie/pyodide/pyodide.mjs";

const base = "omnie-run://local/";
const send = (message) => postMessage(message);

self.onmessage = async (event) => {
  const { mode, entry, files } = event.data;
  try {
    const py = await loadPyodide({
      indexURL: base + "__omnie/pyodide/",
      stdout: (text) => send({ type: "console", level: "log", text }),
      stderr: (text) => send({ type: "console", level: "error", text }),
    });
    const manifest = await (await fetch(base + "__omnie/manifest.json")).json();
    for (const path of manifest) {
      const data = new Uint8Array(await (await fetch(base + path.split("/").map(encodeURIComponent).join("/"))).arrayBuffer());
      const dir = "/project/" + path.split("/").slice(0, -1).join("/");
      py.FS.mkdirTree(dir);
      py.FS.writeFile("/project/" + path, data);
    }
    const shim = await (await fetch(base + "__omnie/runtime/pytest_shim.py")).text();
    py.FS.mkdirTree("/omnie");
    py.FS.writeFile("/omnie/pytest.py", shim);
    // Packages from the offline cache: Pyodide's builds by name, PyPI wheels by URL.
    const packages = await (await fetch(base + "__omnie/python-packages.json")).json();
    const quiet = { messageCallback: () => {}, errorCallback: (text) => send({ type: "console", level: "error", text }) };
    if (packages.lock.length) await py.loadPackage(packages.lock, quiet);
    if (packages.wheels.length) await py.loadPackage(packages.wheels, quiet);
    py.runPython("import os, sys\nos.chdir('/project')\nsys.path[:0] = ['/project', '/omnie']");
    if (mode === "python") {
      py.globals.set("omnie_entry", entry);
      await py.runPythonAsync(`
import runpy, sys, traceback
try:
    runpy.run_path(omnie_entry, run_name="__main__")
except SystemExit as e:
    if e.code not in (None, 0):
        print(f"Exited with {e.code}", file=sys.stderr)
except BaseException:
    traceback.print_exc()
    raise SystemExit("failed")
`).catch((e) => send({ type: "error", text: String(e.message || e).split("\n").filter(Boolean).pop() }));
    } else {
      py.globals.set("omnie_files", py.toPy(files));
      const report = await py.runPythonAsync("import pytest\npytest._omnie_run(omnie_files)");
      for (const r of JSON.parse(report)) send({ type: "test", ...r });
    }
  } catch (e) {
    send({ type: "error", text: String(e.message || e) });
  }
  send({ type: "done" });
};

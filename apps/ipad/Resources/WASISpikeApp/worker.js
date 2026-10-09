// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
import { WASI, File, Directory, PreopenDirectory, OpenFile, ConsoleStdout } from "../vendor/shim/index.js";

async function buildTree(base, files) {
  const root = new Map();
  for (const f of files) {
    const parts = f.path.split("/");
    let dir = root;
    for (const p of parts.slice(0, -1)) dir = dir.get(p).contents;
    const name = parts[parts.length - 1];
    if (f.dir) dir.set(name, new Directory(new Map()));
    else dir.set(name, new File(new Uint8Array(await (await fetch(base + "/" + f.path)).arrayBuffer())));
  }
  return root;
}

self.onmessage = async (e) => {
  const { wasmURL, name, args, env, rootBase, files } = e.data;
  const stdout = [], stderr = [];
  try {
    const fds = [
      new OpenFile(new File([])),
      new ConsoleStdout((b) => stdout.push(...b)),
      new ConsoleStdout((b) => stderr.push(...b)),
    ];
    // The official runner preopens the test's root directory as "/".
    if (rootBase) fds.push(new PreopenDirectory("/", await buildTree(rootBase, files)));
    const wasi = new WASI([name, ...args], Object.entries(env).map(([k, v]) => `${k}=${v}`), fds);
    const module = await WebAssembly.compile(await (await fetch(wasmURL)).arrayBuffer());
    const instance = await WebAssembly.instantiate(module, { wasi_snapshot_preview1: wasi.wasiImport });
    const exitCode = wasi.start(instance);
    const dec = new TextDecoder();
    self.postMessage({ exitCode, stdout: dec.decode(new Uint8Array(stdout)), stderr: dec.decode(new Uint8Array(stderr)) });
  } catch (err) {
    // A Rust test's assert prints its panic to stderr before trapping; keep the last line as the reason.
    const tail = new TextDecoder().decode(new Uint8Array(stderr)).trim().split("\n").filter((l) => !l.startsWith("note:")).slice(-1)[0] || "";
    self.postMessage({ error: String(err && err.message || err) + (tail ? ` — ${tail}` : "") });
  }
};

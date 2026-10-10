// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
// Python code intelligence with Jedi (in Pyodide, offline, long-lived): definitions, references,
// rename, quick info and completions over the project's .py files and the editor's unsaved text.
// Same requests and replies as language-worker.js; offsets are UTF-16, as the editor counts.
import { loadPyodide } from "omnie-run://local/__omnie/pyodide/pyodide.mjs";

const base = "omnie-run://local/";
const texts = new Map();
let py = null;
let handle = null;
let starting = null;

const LANG_PY = String.raw`
import json, os, sys
import jedi

ROOT = "/project"
project = jedi.Project(ROOT, added_sys_path=[ROOT], smart_sys_path=False)

def _script(path, code):
    return jedi.Script(code, path=os.path.join(ROOT, path), project=project)

def _rel(name):
    p = str(name.module_path) if name.module_path else ""
    return p[len(ROOT) + 1:] if p.startswith(ROOT + "/") else None

def _loc(name, extra=None):
    rel = _rel(name)
    if rel is None or name.line is None:
        return None
    out = {"path": rel, "line": name.line, "column": name.column, "name": name.name}
    if extra:
        out.update(extra)
    return out

def handle(request_json, code):
    r = json.loads(request_json)
    op, path, line, col = r["op"], r.get("path"), r.get("line"), r.get("column")
    s = _script(path, code) if path else None
    if op == "definition":
        names = s.goto(line, col, follow_imports=True, follow_builtin_imports=False)
        return json.dumps([l for l in (_loc(n) for n in names) if l])
    if op == "references":
        names = s.get_references(line, col, include_builtins=False)
        return json.dumps([l for l in (_loc(n, {"isDefinition": n.is_definition()}) for n in names) if l])
    if op == "renameInfo" or op == "rename":
        names = s.get_references(line, col, include_builtins=False)
        here = [n for n in names if n.line == line and n.column <= col <= n.column + len(n.name)]
        if not names or not here:
            return json.dumps({"error": "There's no symbol here to rename."})
        outside = [n for n in names if _rel(n) is None]
        if outside:
            return json.dumps({"error": f"{here[0].name} is declared outside the project."})
        if op == "renameInfo":
            return json.dumps({"displayName": here[0].name})
        return json.dumps({"displayName": here[0].name,
                           "edits": [l for l in (_loc(n, {"newText": r["newName"], "length": len(n.name)}) for n in names) if l]})
    if op == "quickInfo":
        names = s.infer(line, col) or s.goto(line, col)
        if not names:
            return "null"
        n = names[0]
        sigs = n.get_signatures() if n.type in ("function", "class") else []
        signature = sigs[0].to_string() if sigs else (n.description or n.name)
        if n.type == "function" and not signature.startswith("def "):
            signature = "def " + signature
        return json.dumps({"kind": n.type, "signature": signature, "documentation": n.docstring(raw=True) or ""})
    if op == "completions":
        found = s.complete(line, col)[: r.get("limit", 60)]
        return json.dumps([{"name": c.name, "kind": c.type, "typed": len(c.name) - len(c.complete)} for c in found])
    if op == "completionDetails":
        for c in s.complete(line, col):
            if c.name == r["name"]:
                sigs = c.get_signatures()
                return json.dumps({"signature": sigs[0].to_string() if sigs else c.description, "documentation": c.docstring(raw=True) or ""})
        return "null"
    raise ValueError("no such request: " + op)
`;

async function start() {
  py = await loadPyodide({ indexURL: base + "__omnie/pyodide/", stdout: () => {}, stderr: () => {} });
  await py.loadPackage(["parso", "jedi"], { messageCallback: () => {}, errorCallback: () => {} });
  await mirror();
  py.runPython(LANG_PY);
  handle = py.globals.get("handle");
}

/// The project's Python files (and package markers) in Pyodide's file system, for imports.
async function mirror() {
  const manifest = await (await fetch(base + "__omnie/manifest.json")).json();
  for (const path of manifest.filter((p) => /\.(py|pyi)$/.test(p))) {
    const text = await (await fetch(base + "__omnie/source/" + path.split("/").map(encodeURIComponent).join("/"))).text();
    write(path, text);
  }
}

function write(path, text) {
  texts.set(path, text);
  py.FS.mkdirTree("/project/" + path.split("/").slice(0, -1).join("/"));
  py.FS.writeFile("/project/" + path, text);
}

/// UTF-16 offset ↔ Jedi's 1-based line and column (code points; the same for everything but
/// characters outside the BMP).
function lineColumn(text, offset) {
  let line = 1, start = 0;
  for (let i = 0; i < offset && i < text.length; i++) if (text[i] === "\n") { line++; start = i + 1; }
  return { line, column: offset - start };
}

function offsetOf(text, line, column) {
  let current = 1, i = 0;
  while (current < line && i < text.length) { if (text[i] === "\n") current++; i++; }
  return i + column;
}

/// A Jedi location as the editor's: offset, length, the line's text.
function place(loc, length) {
  const text = texts.get(loc.path) ?? "";
  const start = offsetOf(text, loc.line, loc.column);
  const lineStart = start - loc.column;
  let lineEnd = text.indexOf("\n", start);
  if (lineEnd < 0) lineEnd = text.length;
  return { path: loc.path, start, length: length ?? loc.name?.length ?? 0, line: loc.line, column: loc.column + 1,
           preview: text.slice(lineStart, lineEnd).trim(), isDefinition: !!loc.isDefinition };
}

function ask(request, code) {
  return JSON.parse(handle(JSON.stringify(request), code));
}

const handlers = {
  async reload() { await mirror(); return true; },

  update({ path, text }) { write(path, text); return true; },

  definition({ path, offset }) {
    const code = texts.get(path) ?? "";
    return ask({ op: "definition", path, ...lineColumn(code, offset) }, code).map((l) => place(l));
  },

  references({ path, offset }) {
    const code = texts.get(path) ?? "";
    return ask({ op: "references", path, ...lineColumn(code, offset) }, code).map((l) => place(l));
  },

  renameInfo({ path, offset }) {
    const code = texts.get(path) ?? "";
    return ask({ op: "renameInfo", path, ...lineColumn(code, offset) }, code);
  },

  rename({ path, offset, newName }) {
    const code = texts.get(path) ?? "";
    const result = ask({ op: "rename", path, newName, ...lineColumn(code, offset) }, code);
    if (result.error) return result;
    return { displayName: result.displayName, edits: result.edits.map((e) => ({ ...place(e, e.length), newText: e.newText })) };
  },

  quickInfo({ path, offset }) {
    const code = texts.get(path) ?? "";
    const info = ask({ op: "quickInfo", path, ...lineColumn(code, offset) }, code);
    return info && { kind: info.kind, signature: info.signature, documentation: info.documentation, tags: [] };
  },

  completions({ path, offset, limit = 60 }) {
    const code = texts.get(path) ?? "";
    const found = ask({ op: "completions", path, limit, ...lineColumn(code, offset) }, code);
    return { entries: found.map((c) => ({ name: c.name, kind: c.kind, insertText: c.name, start: offset - c.typed, length: c.typed })) };
  },

  completionDetails({ path, offset, name }) {
    const code = texts.get(path) ?? "";
    return ask({ op: "completionDetails", path, name, ...lineColumn(code, offset) }, code);
  },
};

self.onmessage = async (e) => {
  const { id, op, ...args } = e.data;
  try {
    if (!handle) { starting = starting ?? start(); await starting; }
    const handler = handlers[op];
    if (!handler) throw new Error("no such request: " + op);
    postMessage({ type: "reply", id, result: await handler(args) });
  } catch (error) {
    postMessage({ type: "reply", id, error: String(error && error.message || error).split("\n").filter(Boolean).pop() });
  }
};

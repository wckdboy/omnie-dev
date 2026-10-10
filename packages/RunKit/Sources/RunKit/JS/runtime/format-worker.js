// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
// Format Document, offline: Prettier for JavaScript, TypeScript, JSON, CSS, HTML, Markdown and YAML
// (with the project's .prettierrc / .prettierrc.json or package.json's "prettier"), Ruff's
// formatter for Python (with ruff.toml's or pyproject.toml's line-length). Replies with the
// formatted text and where the caret goes in it.
import * as prettier from "omnie-run://local/__omnie/packages/prettier/standalone.mjs";
import * as babel from "omnie-run://local/__omnie/packages/prettier/plugins/babel.mjs";
import * as estree from "omnie-run://local/__omnie/packages/prettier/plugins/estree.mjs";
import * as typescript from "omnie-run://local/__omnie/packages/prettier/plugins/typescript.mjs";
import * as postcss from "omnie-run://local/__omnie/packages/prettier/plugins/postcss.mjs";
import * as html from "omnie-run://local/__omnie/packages/prettier/plugins/html.mjs";
import * as markdown from "omnie-run://local/__omnie/packages/prettier/plugins/markdown.mjs";
import * as yaml from "omnie-run://local/__omnie/packages/prettier/plugins/yaml.mjs";

const plugins = [babel, estree, typescript, postcss, html, markdown, yaml];
const base = "omnie-run://local/";
const source = (p) => base + "__omnie/source/" + p.split("/").map(encodeURIComponent).join("/");

async function json(path) {
  try {
    const response = await fetch(source(path));
    return response.ok ? JSON.parse(await response.text()) : null;
  } catch { return null; }
}

/// The project's options: the first config found, as Prettier would (JSON forms only).
async function options() {
  for (const name of [".prettierrc", ".prettierrc.json"]) {
    const found = await json(name);
    if (found) return found;
  }
  return (await json("package.json"))?.prettier ?? {};
}

let ruff = null;

/// Ruff's WebAssembly build, loaded the first time Python is formatted.
async function ruffWorkspace() {
  if (!ruff) {
    const module = await import("omnie-run://local/__omnie/packages/ruff/ruff_wasm.js");
    await module.default({ module_or_path: base + "__omnie/packages/ruff/ruff_wasm_bg.wasm" });
    ruff = module;
  }
  const settings = ruff.Workspace.defaultSettings();
  const lineLength = await pythonLineLength();
  // The defaults come back as a Map.
  if (lineLength) { if (settings instanceof Map) settings.set("line-length", lineLength); else settings["line-length"] = lineLength; }
  return new ruff.Workspace(settings, ruff.PositionEncoding?.Utf16 ?? 1);
}

/// `line-length` from ruff.toml / .ruff.toml, or pyproject.toml's [tool.ruff] (or Black's).
async function pythonLineLength() {
  for (const [file, section] of [["ruff.toml", null], [".ruff.toml", null], ["pyproject.toml", /\[tool\.(ruff|black)\]([\s\S]*?)(\n\[|$)/]]) {
    let text;
    try { const r = await fetch(source(file)); if (!r.ok) continue; text = await r.text(); } catch { continue; }
    const scope = section ? (text.match(section)?.[2] ?? "") : text;
    const found = scope.match(/^\s*line-length\s*=\s*(\d+)/m);
    if (found) return Number(found[1]);
  }
  return null;
}

/// The caret's line and column, carried over to the formatted text (Ruff reports no cursor).
function carryCursor(before, after, cursor) {
  const head = before.slice(0, cursor).split("\n");
  const line = head.length - 1, column = head[head.length - 1].length;
  const lines = after.split("\n");
  const target = Math.min(line, lines.length - 1);
  let offset = 0;
  for (let i = 0; i < target; i++) offset += lines[i].length + 1;
  return offset + Math.min(column, lines[target].length);
}

const handlers = {
  async supports({ path }) {
    const info = await prettier.getFileInfo(path, { plugins }).catch(() => null);
    return !!info?.inferredParser;
  },
  async format({ path, text, cursor }) {
    if (/\.pyi?$/.test(path)) {
      const workspace = await ruffWorkspace();
      try {
        const formatted = workspace.format(text);
        return { text: formatted, cursor: carryCursor(text, formatted, cursor ?? 0) };
      } finally { workspace.free(); }
    }
    const config = await options();
    const result = await prettier.formatWithCursor(text, { ...config, filepath: path, plugins, cursorOffset: cursor ?? 0 });
    return { text: result.formatted, cursor: result.cursorOffset };
  },
};

self.onmessage = async (e) => {
  const { id, op, ...args } = e.data;
  try {
    const handler = handlers[op];
    if (!handler) throw new Error("no such request: " + op);
    postMessage({ type: "reply", id, result: await handler(args) });
  } catch (error) {
    // Prettier's syntax errors carry a code frame; the first line says what and where.
    postMessage({ type: "reply", id, error: String(error && error.message || error).split("\n")[0] });
  }
};

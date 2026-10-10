// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
// Format Document with Prettier, offline: JavaScript, TypeScript, JSON, CSS, HTML, Markdown and
// YAML, with the project's Prettier options (.prettierrc / .prettierrc.json or package.json's
// "prettier"). Replies with the formatted text and where the caret goes in it.
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

const handlers = {
  async supports({ path }) {
    const info = await prettier.getFileInfo(path, { plugins }).catch(() => null);
    return !!info?.inferredParser;
  },
  async format({ path, text, cursor }) {
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

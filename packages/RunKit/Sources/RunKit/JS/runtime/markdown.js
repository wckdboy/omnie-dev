// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
// Markdown preview (PLAN.md §11.1): GitHub-flavored Markdown with marked, ```mermaid blocks drawn
// by Mermaid. Raw HTML in the document is shown as text, so a README can't run scripts here.
import { Marked } from "omnie-run://local/__omnie/packages/marked/marked.esm.js";

const path = new URLSearchParams(location.search).get("file");
const dir = path.includes("/") ? path.slice(0, path.lastIndexOf("/") + 1) : "";
const doc = document.getElementById("doc");
const escape = (s) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
const resolve = (href) => (/^[a-z]+:|^#|^\//i.test(href) ? href : dir + href);

/// Scrolls to the block that holds source `line` (called by the app as the caret moves).
window.__omnieScrollToLine = (line) => {
  const blocks = [...doc.querySelectorAll("[data-line]")];
  let target = blocks[0];
  for (const b of blocks) { if (Number(b.dataset.line) <= line) target = b; else break; }
  target?.scrollIntoView({ block: "start", behavior: "smooth" });
};

const marked = new Marked({
  gfm: true,
  renderer: {
    html: ({ text }) => escape(text),
    code: ({ text, lang }) => lang === "mermaid"
      ? `<div class="mermaid">${escape(text)}</div>`
      : `<pre><code>${escape(text)}</code></pre>`,
    image: ({ href, title, text }) => `<img src="${escape(resolve(href))}" alt="${escape(text)}"${title ? ` title="${escape(title)}"` : ""}>`,
  },
});

try {
  const response = await fetch("omnie-run://local/" + path.split("/").map(encodeURIComponent).join("/"));
  if (!response.ok) throw new Error(`Can't read ${path}`);
  // Each top-level block carries its first source line, so the preview can follow the editor.
  const source = await response.text();
  const tokens = marked.lexer(source);
  let line = 1, html = "";
  for (const token of tokens) {
    const one = Object.assign([token], { links: tokens.links });
    html += token.type === "space" ? marked.parser(one) : `<div data-line="${line}">${marked.parser(one)}</div>`;
    line += (token.raw.match(/\n/g) || []).length;
  }
  doc.innerHTML = html;
  const dark = matchMedia("(prefers-color-scheme: dark)").matches;
  if (window.mermaid && doc.querySelector(".mermaid")) {
    window.mermaid.initialize({ startOnLoad: false, theme: dark ? "dark" : "default", securityLevel: "strict" });
    await window.mermaid.run({ querySelector: ".mermaid" });
  }
  window.webkit?.messageHandlers?.omnieConsole?.postMessage({ level: "log", text: `rendered ${path}: ${doc.querySelectorAll(".mermaid svg").length} diagrams` });
} catch (e) {
  doc.innerHTML = `<p class="error">${escape(String(e.message || e))}</p>`;
  window.webkit?.messageHandlers?.omnieConsole?.postMessage({ level: "error", text: String(e.message || e) });
}

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
  doc.innerHTML = marked.parse(await response.text());
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

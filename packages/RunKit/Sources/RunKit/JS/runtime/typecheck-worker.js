// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
// Type-checks a project with the TypeScript 5 compiler, offline, in a worker. The compiler reads
// files synchronously, so the project's sources and the lib files are fetched into memory first.
importScripts("omnie-run://local/__omnie/runtime/ts-project.js");

self.onmessage = async () => {
  try {
    const started = performance.now();
    const files = new Map();
    await omnieLoadProject(files);
    const exists = (n) => files.has(n);
    const host = {
      getSourceFile: (name, version) => (files.has(name) ? ts.createSourceFile(name, files.get(name), version, true) : undefined),
      getDefaultLibFileName: (o) => "/lib/" + ts.getDefaultLibFileName(o),
      writeFile: () => {},
      getCurrentDirectory: () => "/project",
      getDirectories: () => [],
      fileExists: exists,
      readFile: (n) => files.get(n),
      getCanonicalFileName: (n) => n,
      useCaseSensitiveFileNames: () => true,
      getNewLine: () => "\n",
      directoryExists: omnieDirectoryExists(files),
    };
    const { options, roots: allRoots } = omnieConfig(files);
    const roots = allRoots.filter((r) => r !== "/lib/omnie-stage.d.ts");

    const program = ts.createProgram({ rootNames: allRoots, options, host });
    const category = (c) => (c === ts.DiagnosticCategory.Error ? "error" : c === ts.DiagnosticCategory.Warning ? "warning" : "info");
    const diagnostics = [];
    for (const d of ts.getPreEmitDiagnostics(program)) {
      const message = ts.flattenDiagnosticMessageText(d.messageText, "\n");
      // No npm cache yet: a bare package with no types here isn't the project's fault.
      if ((d.code === 2307 || d.code === 7016) && /['"](?![./])[^'"]+['"]/.test(message)) continue;
      if (d.file && (!d.file.fileName.startsWith("/project/") || d.file.fileName.includes("/node_modules/"))) continue;
      const entry = { code: d.code, category: category(d.category), message };
      if (d.file && d.start !== undefined) {
        const { line, character } = d.file.getLineAndCharacterOfPosition(d.start);
        Object.assign(entry, { path: d.file.fileName.slice("/project/".length), line: line + 1, column: character + 1, start: d.start, length: d.length ?? 0 });
      }
      diagnostics.push(entry);
    }
    postMessage({ type: "diagnostics", diagnostics, files: roots.length, ms: Math.round(performance.now() - started) });
  } catch (e) {
    postMessage({ type: "error", text: String(e && e.message || e) });
  }
  postMessage({ type: "done" });
};

// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
// Type-checks a project with the TypeScript 5 compiler, offline, in a worker. The compiler reads
// files synchronously, so the project's sources and the lib files are fetched into memory first.
importScripts("omnie-run://local/__omnie/packages/typescript/typescript.js");

const base = "omnie-run://local/";
const text = async (url) => (await fetch(url)).text();
const projectURL = (p) => base + "__omnie/source/" + p.split("/").map(encodeURIComponent).join("/");

self.onmessage = async () => {
  try {
    const started = performance.now();
    const files = new Map();
    const libs = (await text(base + "__omnie/packages/typescript/libs.txt")).split("\n").filter(Boolean);
    await Promise.all(libs.map(async (n) => files.set("/lib/" + n, await text(base + "__omnie/packages/typescript/lib/" + n))));
    const manifest = JSON.parse(await text(base + "__omnie/manifest.json"));
    const wanted = manifest.filter((p) => /\.(ts|tsx|mts|cts)$/.test(p) || /(^|\/)(tsconfig|jsconfig)\.json$/.test(p) || p.endsWith(".json"));
    await Promise.all(wanted.map(async (p) => files.set("/project/" + p, await text(projectURL(p)))));
    // Cached npm packages' declarations, laid out as node_modules so imports resolve as usual.
    const packages = JSON.parse(await text(base + "__omnie/npm-types.json"));
    await Promise.all(packages.flatMap((pkg) => pkg.files.map(async (f) => {
      const url = base + "__omnie/npm-raw/" + [pkg.name, pkg.version, f].join("/").split("/").map(encodeURIComponent).join("/");
      files.set("/project/node_modules/" + pkg.name + "/" + f, await text(url));
    })));

    // The Stage's scene-module API, so `export default ({ scene, onFrame }: OmnieStage) => …` checks.
    files.set("/lib/omnie-stage.d.ts", `
      interface OmnieStage {
        THREE: typeof import("three");
        scene: import("three").Scene;
        camera: import("three").PerspectiveCamera;
        renderer: import("three").WebGLRenderer;
        controls: { target: import("three").Vector3; update(): void; enabled: boolean };
        /** Called every frame with the seconds since the last frame and since the start. */
        onFrame(callback: (delta: number, elapsed: number) => void): void;
      }`);
    const exists = (n) => files.has(n);
    const entries = (dir) => {
      const prefix = dir.endsWith("/") ? dir : dir + "/";
      const found = { files: new Set(), directories: new Set() };
      for (const k of files.keys()) {
        if (!k.startsWith(prefix)) continue;
        const [first, ...more] = k.slice(prefix.length).split("/");
        (more.length ? found.directories : found.files).add(first);
      }
      return { files: [...found.files], directories: [...found.directories] };
    };
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
      directoryExists: (d) => { const dir = d.endsWith("/") ? d : d + "/"; for (const k of files.keys()) if (k.startsWith(dir)) return true; return false; },
    };

    let options = {
      strict: true, target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext, moduleResolution: ts.ModuleResolutionKind.Bundler,
      jsx: ts.JsxEmit.ReactJSX, lib: ["lib.es2022.d.ts", "lib.dom.d.ts", "lib.dom.iterable.d.ts"], resolveJsonModule: true,
      esModuleInterop: true, allowImportingTsExtensions: true, types: [],
      // Every file is a module, as Vite's tsconfig has it (pages load them with type="module").
      moduleDetection: ts.ModuleDetectionKind.Force,
    };
    let roots = [...files.keys()].filter((k) => k.startsWith("/project/") && /\.(ts|tsx|mts|cts)$/.test(k) && !k.includes("/node_modules/"));
    const configPath = files.has("/project/tsconfig.json") ? "/project/tsconfig.json" : null;
    if (configPath) {
      const parsedJSON = ts.parseConfigFileTextToJson(configPath, files.get(configPath));
      const configHost = {
        useCaseSensitiveFileNames: true, fileExists: exists, readFile: (n) => files.get(n),
        // include/exclude globs, matched over the in-memory files.
        readDirectory: (root, extensions, excludes, includes, depth) =>
          ts.matchFiles(root, extensions, excludes, includes, true, "/project", depth, entries, (p) => p),
      };
      const parsed = ts.parseJsonConfigFileContent(parsedJSON.config ?? {}, configHost, "/project", undefined, configPath);
      options = { ...parsed.options, types: parsed.options.types ?? [] };
      if (parsed.fileNames.length) roots = parsed.fileNames;
    }
    Object.assign(options, { noEmit: true, skipLibCheck: true });

    const program = ts.createProgram({ rootNames: [...roots, "/lib/omnie-stage.d.ts"], options, host });
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

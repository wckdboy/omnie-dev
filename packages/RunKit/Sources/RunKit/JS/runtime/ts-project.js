// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
// A TypeScript project in memory, shared by the type checker and the language service: the lib
// files, the project's sources and JSON, cached npm declarations, and its compiler options from
// tsconfig.json (or Vite-like defaults). The compiler reads files synchronously, so all of it is
// fetched first.
importScripts("omnie-run://local/__omnie/packages/typescript/typescript.js");

const omnieBase = "omnie-run://local/";
const omnieText = async (url) => (await fetch(url)).text();
const omnieProjectURL = (p) => omnieBase + "__omnie/source/" + p.split("/").map(encodeURIComponent).join("/");
const omnieSourcePattern = /\.(ts|tsx|mts|cts|js|jsx|mjs|cjs)$/;

/// Loads everything into `files` (a Map of absolute name → text). `withJS` adds JavaScript sources
/// (the language service answers for them too; the type checker leaves them alone).
async function omnieLoadProject(files, { withJS = false } = {}) {
  const libs = (await omnieText(omnieBase + "__omnie/packages/typescript/libs.txt")).split("\n").filter(Boolean);
  await Promise.all(libs.map(async (n) => files.set("/lib/" + n, await omnieText(omnieBase + "__omnie/packages/typescript/lib/" + n))));
  const manifest = JSON.parse(await omnieText(omnieBase + "__omnie/manifest.json"));
  const source = withJS ? omnieSourcePattern : /\.(ts|tsx|mts|cts)$/;
  const wanted = manifest.filter((p) => source.test(p) || /(^|\/)(tsconfig|jsconfig)\.json$/.test(p) || p.endsWith(".json"));
  await Promise.all(wanted.map(async (p) => files.set("/project/" + p, await omnieText(omnieProjectURL(p)))));
  // Cached npm packages' declarations, laid out as node_modules so imports resolve as usual.
  const packages = JSON.parse(await omnieText(omnieBase + "__omnie/npm-types.json"));
  await Promise.all(packages.flatMap((pkg) => pkg.files.map(async (f) => {
    const url = omnieBase + "__omnie/npm-raw/" + [pkg.name, pkg.version, f].join("/").split("/").map(encodeURIComponent).join("/");
    files.set("/project/node_modules/" + pkg.name + "/" + f, await omnieText(url));
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
}

/// The directory view the config parser and module resolution need, over the in-memory files.
function omnieEntries(files) {
  return (dir) => {
    const prefix = dir.endsWith("/") ? dir : dir + "/";
    const found = { files: new Set(), directories: new Set() };
    for (const k of files.keys()) {
      if (!k.startsWith(prefix)) continue;
      const [first, ...more] = k.slice(prefix.length).split("/");
      (more.length ? found.directories : found.files).add(first);
    }
    return { files: [...found.files], directories: [...found.directories] };
  };
}

function omnieDirectoryExists(files) {
  return (d) => { const dir = d.endsWith("/") ? d : d + "/"; for (const k of files.keys()) if (k.startsWith(dir)) return true; return false; };
}

/// Compiler options and root files: tsconfig.json's when there is one.
function omnieConfig(files, { withJS = false } = {}) {
  let options = {
    strict: true, target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext, moduleResolution: ts.ModuleResolutionKind.Bundler,
    jsx: ts.JsxEmit.ReactJSX, lib: ["lib.es2022.d.ts", "lib.dom.d.ts", "lib.dom.iterable.d.ts"], resolveJsonModule: true,
    esModuleInterop: true, allowImportingTsExtensions: true, types: [],
    // Every file is a module, as Vite's tsconfig has it (pages load them with type="module").
    moduleDetection: ts.ModuleDetectionKind.Force,
  };
  const pattern = withJS ? omnieSourcePattern : /\.(ts|tsx|mts|cts)$/;
  let roots = [...files.keys()].filter((k) => k.startsWith("/project/") && pattern.test(k) && !k.includes("/node_modules/"));
  const configPath = files.has("/project/tsconfig.json") ? "/project/tsconfig.json" : files.has("/project/jsconfig.json") ? "/project/jsconfig.json" : null;
  if (configPath) {
    const parsedJSON = ts.parseConfigFileTextToJson(configPath, files.get(configPath));
    const configHost = {
      useCaseSensitiveFileNames: true, fileExists: (n) => files.has(n), readFile: (n) => files.get(n),
      // include/exclude globs, matched over the in-memory files.
      readDirectory: (root, extensions, excludes, includes, depth) =>
        ts.matchFiles(root, extensions, excludes, includes, true, "/project", depth, omnieEntries(files), (p) => p),
    };
    const parsed = ts.parseJsonConfigFileContent(parsedJSON.config ?? {}, configHost, "/project", undefined, configPath);
    options = { ...parsed.options, types: parsed.options.types ?? [] };
    if (parsed.fileNames.length) roots = parsed.fileNames;
  }
  if (withJS) Object.assign(options, { allowJs: true, checkJs: options.checkJs ?? false });
  Object.assign(options, { noEmit: true, skipLibCheck: true });
  return { options, roots: [...roots, "/lib/omnie-stage.d.ts"] };
}

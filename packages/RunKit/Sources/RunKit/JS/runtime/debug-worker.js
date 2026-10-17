// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
// RunKit's debugger runtime (PLAN.md §5.3): runs a project's modules with a hook at the start of
// every statement — and around every function body — so a breakpoint or a step can stop execution.
// Stopping is synchronous: the worker parks on a request the app holds open (Debugger.swift) and
// reads the chosen action back from its response. Modules load through a small CommonJS loader over
// the project's own files; npm packages aren't loaded yet.
//
// The call stack is kept here rather than read from `Error().stack`: JavaScriptCore reports a single
// frame for code built with `new Function`, so `__omnieEnter`/`__omnieExit` maintain it instead.
const base = "omnie-run://local/";
importScripts(base + "__omnie/packages/typescript/typescript.js");

const send = (message) => postMessage(message);
const format = (value) => {
  if (typeof value === "string") return value;
  if (value instanceof Error) return `${value.name}: ${value.message}`;
  try { return JSON.stringify(value) ?? String(value); } catch { return String(value); }
};
for (const level of ["log", "info", "warn", "error", "debug"]) {
  console[level] = (...args) => send({ type: "console", level, text: args.map(format).join(" ") });
}

const projectURL = (p) => base + "__omnie/source/" + p.split("/").map(encodeURIComponent).join("/");

class Stop {}
let stopped = false;
let stepMode = null;            // "into" | "over" | "out"
let stepDepth = 0;
let hit = null;                 // what the last __omnieH decided, for the snapshot that follows
const breakpoints = new Set();  // "fileId:line"
const breakpointsByFile = new Map();   // path -> Map<line, condition|null>, from the app
let conditions = new Map();     // "fileId:line" -> condition expression
let importMap = {};             // bare specifier -> cache-relative file
let npmFiles = new Set();       // the cached packages' files
let files = new Set();          // the project's files, for resolution
const modules = new Map();      // path -> module record
const ids = new Map();          // path -> fileId
const names = new Map();        // fileId -> path
let nextId = 0;
const callStack = [];           // { name, file, line } per function (and each module's top level)

const pathOf = (id) => names.get(id) ?? `#${id}`;
const depth = () => callStack.length;

/// The stack to show: where the stop is, then its callers.
function frames(id, line) {
  if (!callStack.length) return [{ file: pathOf(id), line, column: 0, name: "" }];
  const top = callStack[callStack.length - 1];
  const out = [{ file: pathOf(id), line, column: 0, name: top.name }];
  for (let i = callStack.length - 2; i >= 0; i--) out.push({ file: callStack[i].file, line: callStack[i].line, column: 0, name: callStack[i].name });
  return out;
}

/// Blocks on the app: the request is held until the user chooses, and its response says what to do
/// (a plain action, or an expression to evaluate in the paused frame).
function pause(id, file, line, reason, atDepth, locals, evaluated) {
  const xhr = new XMLHttpRequest();
  xhr.open("POST", base + "__omnie/debug/pause", false);
  xhr.setRequestHeader("Content-Type", "application/json");
  xhr.send(JSON.stringify({ file, line, reason, stack: frames(id, line), locals, evaluated }));
  const text = xhr.responseText || "";
  try { return JSON.parse(text); } catch { return { action: text || "continue" }; }
}

function apply(action, atDepth) {
  if (action === "stop") { stopped = true; throw new Stop(); }
  if (action === "stepInto") { stepMode = "into"; stepDepth = atDepth; }
  else if (action === "stepOver") { stepMode = "over"; stepDepth = atDepth; }
  else if (action === "stepOut") { stepMode = "out"; stepDepth = atDepth; }
  else stepMode = null;
}

globalThis.__omnieEnter = function (name, id, line) {
  callStack.push({ name, file: pathOf(id), line });
};
globalThis.__omnieExit = function () { callStack.pop(); };

globalThis.__omnieH = function (id, line) {
  if (stopped) return false;
  if (stepMode) {
    const now = depth();
    const stop = stepMode === "into" || (stepMode === "over" && now <= stepDepth) || (stepMode === "out" && now < stepDepth);
    if (!stop) return false;
    hit = { id, line, reason: "step", depth: now };
    return true;
  }
  if (breakpoints.has(`${id}:${line}`)) {
    hit = { id, line, reason: "breakpoint", depth: depth() };
    return true;
  }
  return false;
};

/// Runs an expression in the paused frame: `evalThunk` is `(e) => eval(e)` made where the statement
/// is, so a direct eval sees the locals there.
function evaluate(evalThunk, expression) {
  try {
    return { expression, result: format(evalThunk(expression)) };
  } catch (e) {
    return { expression, result: format(e), failed: true };
  }
}

/// The raw value of an expression, for a breakpoint's condition.
function evalRaw(evalThunk, expression) {
  try {
    return { ok: true, value: evalThunk(expression) };
  } catch (e) {
    return { ok: false, error: e };
  }
}

globalThis.__omnieSnap = function (id, line, evalThunk, localsThunk) {
  const decision = hit ?? { id, line, reason: "breakpoint", depth: depth() };
  hit = null;
  // A conditional breakpoint stops only when its condition is truthy in this frame.
  if (decision.reason === "breakpoint") {
    const condition = conditions.get(`${id}:${line}`);
    if (condition) {
      const result = evalRaw(evalThunk, condition);
      if (!result.ok) {
        console.warn(`Breakpoint condition failed (${condition}): ${format(result.error)}`);
        return;
      }
      if (!result.value) return;
    }
  }
  let locals = [];
  try {
    const values = localsThunk();
    locals = Object.keys(values).map((name) => ({ name, value: format(values[name]) }));
  } catch (e) { /* a thunk that threw loses its locals, not the pause */ }
  let evaluated = null;
  // Staying stopped to evaluate: the app asks again with the expression, and sees the result with
  // the next stop.
  for (;;) {
    const answer = pause(id, pathOf(id), line, decision.reason, decision.depth, locals, evaluated);
    if (answer.action === "eval" && typeof answer.expression === "string") {
      evaluated = evaluate(evalThunk, answer.expression);
      continue;
    }
    apply(answer.action, decision.depth);
    return;
  }
};

// MARK: Instrumentation

function kind(path) {
  if (path.endsWith(".tsx")) return ts.ScriptKind.TSX;
  if (path.endsWith(".jsx")) return ts.ScriptKind.JSX;
  if (path.endsWith(".js") || path.endsWith(".mjs") || path.endsWith(".cjs")) return ts.ScriptKind.JS;
  return ts.ScriptKind.TS;
}

/// TypeScript/JSX to CommonJS, without hooks (packages).
function transpile(source, path) {
  return ts.transpileModule(source, {
    fileName: path,
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, esModuleInterop: true, jsx: ts.JsxEmit.ReactJSX },
  }).outputText;
}

/// Inserts a hook before every statement, and an enter/exit pair around every function body, on the
/// statements' own lines so line numbers are unchanged.
function instrument(source, path, id) {
  const file = ts.createSourceFile(path, source, ts.ScriptTarget.ES2022, true, kind(path));
  const insertions = [];
  const scopes = [];   // Set<string> per visible scope, innermost last
  const visible = () => {
    const all = new Set();
    for (const scope of scopes) for (const name of scope) all.add(name);
    return [...all].sort();
  };
  const addBinding = (name, into) => {
    if (!name) return;
    if (ts.isIdentifier(name)) into.add(name.text);
    else if (ts.isObjectBindingPattern(name) || ts.isArrayBindingPattern(name)) for (const element of name.elements) addBinding(element.name, into);
  };
  const declare = (statement, into) => {
    if (ts.isVariableStatement(statement)) for (const d of statement.declarationList.declarations) addBinding(d.name, into);
    else if ((ts.isFunctionDeclaration(statement) || ts.isClassDeclaration(statement) || ts.isEnumDeclaration(statement)) && statement.name) into.add(statement.name.text);
    // A loop's own bindings (`for (let i = …)`) are in scope for its body.
    const initializer = ts.isForStatement(statement) || ts.isForOfStatement(statement) || ts.isForInStatement(statement) ? statement.initializer : null;
    if (initializer && ts.isVariableDeclarationList(initializer)) for (const d of initializer.declarations) addBinding(d.name, into);
  };
  const hook = (statement) => {
    if (ts.isEmptyStatement(statement)) return;
    const start = statement.getStart(file);
    const line = file.getLineAndCharacterOfPosition(start).line + 1;
    const inScope = visible();
    const body = inScope.length
      ? `{const v={};${inScope.map((n) => `try{v[${JSON.stringify(n)}]=${n}}catch(e){}`).join("")}return v}`
      : "({})";
    insertions.push({ pos: start, text: `if(__omnieH(${id},${line}))__omnieSnap(${id},${line},(e)=>eval(e),()=>${body});` });
  };
  const walk = (node) => {
    if (ts.isFunctionLike(node)) {
      const scope = new Set();
      for (const parameter of node.parameters ?? []) addBinding(parameter.name, scope);
      if (node.name && ts.isIdentifier(node.name)) scope.add(node.name.text);
      scopes.push(scope);
      if (node.body) {
        if (ts.isBlock(node.body)) {
          const open = node.body.getStart(file) + 1;
          const close = node.body.end - 1;
          const name = node.name && ts.isIdentifier(node.name) ? node.name.text : "";
          const line = file.getLineAndCharacterOfPosition(node.getStart(file)).line + 1;
          insertions.push({ pos: open, text: `__omnieEnter(${JSON.stringify(name)},${id},${line});try{` });
          insertions.push({ pos: close, text: `}finally{__omnieExit()}` });
        }
        walk(node.body);
      }
      scopes.pop();
      return;
    }
    if (ts.isBlock(node) || ts.isModuleBlock(node) || ts.isCaseClause(node) || ts.isSourceFile(node)) {
      const scope = new Set();
      scopes.push(scope);
      for (const statement of node.statements) {
        hook(statement);
        declare(statement, scope);
        walk(statement);
      }
      scopes.pop();
      return;
    }
    ts.forEachChild(node, walk);
  };
  walk(file);

  let out = source;
  for (const { pos, text } of insertions.sort((a, b) => b.pos - a.pos)) out = out.slice(0, pos) + text + out.slice(pos);
  return transpile(out, path);
}

// MARK: The loader

const normal = (path) => {
  const parts = [];
  for (const part of path.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") parts.pop();
    else parts.push(part);
  }
  return parts.join("/");
};

/// A project-relative specifier to a project file.
function resolve(spec, fromDir) {
  const target = spec.startsWith("/") ? normal(spec) : normal(fromDir + "/" + spec);
  const candidates = [target, `${target}.ts`, `${target}.tsx`, `${target}.js`, `${target}.mjs`, `${target}.jsx`, `${target}.json`,
    `${target}/index.ts`, `${target}/index.tsx`, `${target}/index.js`];
  return candidates.find((c) => files.has(c)) ?? null;
}

/// A project file, read synchronously (module loading is synchronous, like Node's `require`).
function syncText(url) {
  const xhr = new XMLHttpRequest();
  xhr.open("GET", url, false);
  xhr.send();
  if (xhr.status !== 200) throw new Error(`Can't read ${url.replace(base, "")} (${xhr.status}).`);
  return xhr.responseText;
}

// MARK: npm packages (the offline cache)

const npmModules = new Map();   // cache-relative path -> module record
const packageOf = (spec) => (spec.startsWith("@") ? spec.split("/").slice(0, 2).join("/") : spec.split("/")[0]);

/// A bare specifier to a cached file: "react", "react/jsx-runtime", "@scope/pkg/sub".
function resolvePackage(spec) {
  if (importMap[spec]) return importMap[spec];
  const name = packageOf(spec);
  const folder = importMap[name + "/"];
  if (!folder) return null;
  const base = folder.replace(/\/$/, "");
  const rest = spec.slice(name.length + 1);
  const candidates = [rest, rest + ".js", rest + ".mjs", rest + ".cjs", rest + ".json",
    rest + "/index.js", rest + "/index.mjs", rest + "/index.json"].map((p) => `${base}/${p}`);
  return candidates.find((c) => npmFiles.has(c)) ?? null;
}

/// A relative import inside a package.
function resolveInsidePackage(spec, fromDir) {
  const target = normal(fromDir + "/" + spec);
  const candidates = [target, target + ".js", target + ".mjs", target + ".cjs", target + ".json",
    target + "/index.js", target + "/index.mjs", target + "/index.json"];
  return candidates.find((c) => npmFiles.has(c)) ?? null;
}

/// Loads a cached package file. Packages aren't instrumented: they run as they are (a breakpoint in
/// one won't stop), but the project's code around them can still be stepped through.
function requirePackage(spec, fromDir) {
  const path = spec.startsWith(".") || spec.startsWith("/") ? resolveInsidePackage(spec, fromDir) : resolvePackage(spec);
  if (!path) throw new Error(`Can't find ${spec}: the debugger loads the project's files and the packages in the offline cache (run \`npm install ${packageOf(spec)}\` first).`);
  if (npmModules.has(path)) return npmModules.get(path).exports;
  const dir = path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "";
  const record = { exports: {} };
  npmModules.set(path, record);
  const text = syncText(base + "__omnie/npm-raw/" + path.split("/").map(encodeURIComponent).join("/"));
  if (path.endsWith(".json")) {
    record.exports = JSON.parse(text);
    return record.exports;
  }
  const code = transpile(text, path);
  const run = new Function("exports", "require", "module", "__filename", "__dirname", code);
  run(record.exports, (s) => requirePackage(s, dir), record, path, dir);
  return record.exports;
}

function require(spec, fromDir) {
  if (!spec.startsWith(".") && !spec.startsWith("/")) return requirePackage(spec, fromDir);
  const path = resolve(spec, fromDir);
  if (!path) throw new Error(`Can't find ${spec} (from ${fromDir}/) in the project.`);
  if (modules.has(path)) return modules.get(path).exports;
  const dir = path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "";
  const id = nextId++;
  ids.set(path, id);
  names.set(id, path);
  for (const [line, condition] of breakpointsByFile.get(path) ?? []) {
    breakpoints.add(`${id}:${line}`);
    if (condition) conditions.set(`${id}:${line}`, condition);
  }

  const record = { exports: {} };
  modules.set(path, record);
  if (path.endsWith(".json")) {
    record.exports = JSON.parse(syncText(projectURL(path)));
    return record.exports;
  }
  const code = instrument(syncText(projectURL(path)), path, id);
  const run = new Function("exports", "require", "module", "__filename", "__dirname", code);
  callStack.push({ name: "", file: path, line: 1 });
  try {
    run(record.exports, (s) => require(s, dir), record, path, dir);
  } finally {
    callStack.pop();
  }
  return record.exports;
}

self.onmessage = async (event) => {
  const { entry, breakpoints: requested } = event.data;
  files = new Set(await (await fetch(base + "__omnie/manifest.json")).json());
  const map = await (await fetch(base + "__omnie/importmap.json")).json();
  for (const [name, url] of Object.entries(map)) importMap[name] = url.replace(base + "__omnie/npm/", "");
  npmFiles = new Set(await (await fetch(base + "__omnie/npm-files.json")).json());
  for (const b of requested ?? []) {
    if (!breakpointsByFile.has(b.file)) breakpointsByFile.set(b.file, new Map());
    breakpointsByFile.get(b.file).set(b.line, b.condition ?? null);
  }
  try {
    require("./" + entry.replace(/^\.\//, ""), "");
  } catch (e) {
    if (!(e instanceof Stop)) send({ type: "error", text: `Uncaught ${format(e)}` });
  }
  send({ type: "done" });
};

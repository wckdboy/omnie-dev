// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
// The TypeScript language service over the project, offline and long-lived: definitions,
// references, rename, quick info and completions for TypeScript and JavaScript, answering for the
// editor's unsaved text. Requests are { id, op, path, offset, ... }; replies { type: "reply", id, result }.
importScripts("omnie-run://local/__omnie/runtime/ts-project.js");

const files = new Map();
const versions = new Map();
let service = null;
let config = null;
let loading = null;

const abs = (path) => "/project/" + path;
const rel = (name) => (name.startsWith("/project/") ? name.slice("/project/".length) : null);

async function load() {
  files.clear();
  await omnieLoadProject(files, { withJS: true });
  config = omnieConfig(files, { withJS: true });
  if (!service) {
    const host = {
      getScriptFileNames: () => config.roots,
      getScriptVersion: (n) => String(versions.get(n) ?? 0),
      getScriptSnapshot: (n) => (files.has(n) ? ts.ScriptSnapshot.fromString(files.get(n)) : undefined),
      getCurrentDirectory: () => "/project",
      getCompilationSettings: () => config.options,
      getDefaultLibFileName: (o) => "/lib/" + ts.getDefaultLibFileName(o),
      fileExists: (n) => files.has(n),
      readFile: (n) => files.get(n),
      readDirectory: (root, extensions, excludes, includes, depth) =>
        ts.matchFiles(root, extensions, excludes, includes, true, "/project", depth, omnieEntries(files), (p) => p),
      directoryExists: omnieDirectoryExists(files),
      getDirectories: (d) => omnieEntries(files)(d).directories,
      useCaseSensitiveFileNames: () => true,
    };
    service = ts.createLanguageService(host, ts.createDocumentRegistry(true, "/project"));
  }
  for (const name of files.keys()) versions.set(name, (versions.get(name) ?? 0) + 1);
}

/// Line and column (1-based) of an offset in a file, and that line's text, for lists.
function place(name, start, length) {
  const text = files.get(name) ?? "";
  const source = service.getProgram()?.getSourceFile(name);
  let line = 0, character = start;
  if (source) ({ line, character } = source.getLineAndCharacterOfPosition(start));
  const lineStart = start - character;
  let lineEnd = text.indexOf("\n", start);
  if (lineEnd < 0) lineEnd = text.length;
  return { path: rel(name), start, length, line: line + 1, column: character + 1, preview: text.slice(lineStart, lineEnd).trim() };
}

const display = (parts) => (parts ?? []).map((p) => p.text).join("");

const handlers = {
  async reload() { await load(); return true; },

  /// The editor's text for a file, saved or not.
  update({ path, text }) {
    const name = abs(path);
    files.set(name, text);
    versions.set(name, (versions.get(name) ?? 0) + 1);
    if (!config.roots.includes(name) && omnieSourcePattern.test(name)) config.roots.push(name);
    return true;
  },

  definition({ path, offset }) {
    const found = service.getDefinitionAndBoundSpan(abs(path), offset);
    return (found?.definitions ?? []).filter((d) => rel(d.fileName) || d.fileName.startsWith("/project/node_modules/"))
      .map((d) => ({ ...place(d.fileName, d.textSpan.start, d.textSpan.length), name: d.name, kind: d.kind }));
  },

  references({ path, offset }) {
    const found = service.findReferences(abs(path), offset) ?? [];
    return found.flatMap((symbol) => symbol.references
      .filter((r) => rel(r.fileName) && !r.fileName.includes("/node_modules/"))
      .map((r) => {
        // An import's references group under the alias; the declaration is the symbol's definition.
        const declares = r.isDefinition || (r.fileName === symbol.definition.fileName && r.textSpan.start === symbol.definition.textSpan.start);
        return { ...place(r.fileName, r.textSpan.start, r.textSpan.length), isDefinition: !!declares, isWrite: !!r.isWriteAccess };
      }));
  },

  rename({ path, offset, newName }) {
    const info = service.getRenameInfo(abs(path), offset, { allowRenameOfImportPath: false });
    if (!info.canRename) return { error: info.localizedErrorMessage || "This can't be renamed." };
    const locations = service.findRenameLocations(abs(path), offset, false, false, { providePrefixAndSuffixTextForRename: true }) ?? [];
    const outside = locations.find((l) => !rel(l.fileName) || l.fileName.includes("/node_modules/"));
    if (outside) return { error: `${info.displayName} is declared outside the project (${outside.fileName.replace("/project/", "")}).` };
    const edits = locations.map((l) => ({
      ...place(l.fileName, l.textSpan.start, l.textSpan.length),
      newText: (l.prefixText ?? "") + newName + (l.suffixText ?? ""),
    }));
    return { displayName: info.displayName, kind: info.kind, edits };
  },

  renameInfo({ path, offset }) {
    const info = service.getRenameInfo(abs(path), offset, { allowRenameOfImportPath: false });
    return info.canRename ? { displayName: info.displayName, kind: info.kind } : { error: info.localizedErrorMessage };
  },

  quickInfo({ path, offset }) {
    const info = service.getQuickInfoAtPosition(abs(path), offset);
    if (!info) return null;
    return {
      kind: info.kind, signature: display(info.displayParts), documentation: display(info.documentation),
      tags: (info.tags ?? []).map((t) => `@${t.name} ${display(t.text)}`.trim()),
      start: info.textSpan.start, length: info.textSpan.length,
    };
  },

  completions({ path, offset, limit = 60 }) {
    const found = service.getCompletionsAtPosition(abs(path), offset, {
      includeCompletionsWithInsertText: true, includeCompletionsForModuleExports: false, includeAutomaticOptionalChainCompletions: true,
    });
    if (!found) return { entries: [] };
    // What's typed of the word so far, to filter and rank by.
    const text = files.get(abs(path)) ?? "";
    let start = offset;
    while (start > 0 && /[\w$]/.test(text[start - 1])) start--;
    const prefix = text.slice(start, offset).toLowerCase();
    const entries = found.entries
      .filter((e) => !prefix || e.name.toLowerCase().startsWith(prefix) || e.name.toLowerCase().includes(prefix))
      .sort((a, b) => {
        const ap = a.name.toLowerCase().startsWith(prefix) ? 0 : 1, bp = b.name.toLowerCase().startsWith(prefix) ? 0 : 1;
        return ap - bp || a.sortText.localeCompare(b.sortText) || a.name.localeCompare(b.name);
      })
      .slice(0, limit)
      .map((e) => ({
        name: e.name, kind: e.kind, insertText: e.insertText ?? e.name,
        start: e.replacementSpan?.start ?? start, length: e.replacementSpan?.length ?? offset - start,
      }));
    return { entries, isMember: !!found.isMemberCompletion };
  },

  completionDetails({ path, offset, name }) {
    const d = service.getCompletionEntryDetails(abs(path), offset, name, undefined, undefined, undefined, undefined);
    return d ? { signature: display(d.displayParts), documentation: display(d.documentation) } : null;
  },
};

self.onmessage = async (e) => {
  const { id, op, ...args } = e.data;
  try {
    if (!service) { loading = loading ?? load(); await loading; }
    const handler = handlers[op];
    if (!handler) throw new Error("no such request: " + op);
    postMessage({ type: "reply", id, result: await handler(args) });
  } catch (error) {
    postMessage({ type: "reply", id, error: String(error && error.message || error) });
  }
};

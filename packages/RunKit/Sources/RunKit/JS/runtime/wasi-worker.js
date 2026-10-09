// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
// RunKit's WASI preview1 (PLAN.md §8, L1 in §25): runs a wasm32-wasip1 program in this worker
// against the project. The project is an inode tree here: files load from the project on first
// read; writes, renames, links and deletions stay here and are handed to Swift at exit, which
// applies them inside the project. Paths can't leave the directory they're resolved from (no
// absolute paths, no ".." past it), rights only shrink, and there are no sockets. A memory cap is
// checked at every system call; the run's timeout stops runaways.
const base = "omnie-run://local/";
importScripts(base + "__omnie/runtime/wasm-fuel.js");
const encoder = new TextEncoder(), decoder = new TextDecoder();

const E = { SUCCESS: 0, ACCES: 2, BADF: 8, EXIST: 20, INVAL: 28, IO: 29, ISDIR: 31, LOOP: 32, NAMETOOLONG: 37, NOENT: 44,
  NOSYS: 52, NOTDIR: 54, NOTEMPTY: 55, NOTSOCK: 57, NOTSUP: 58, PERM: 63, SPIPE: 70, XDEV: 75, NOTCAPABLE: 76 };
const T = { UNKNOWN: 0, CHAR: 2, DIR: 3, FILE: 4, SYMLINK: 7 };
const R = {}; // rights bits
["FD_DATASYNC", "FD_READ", "FD_SEEK", "FD_FDSTAT_SET_FLAGS", "FD_SYNC", "FD_TELL", "FD_WRITE", "FD_ADVISE", "FD_ALLOCATE",
  "PATH_CREATE_DIRECTORY", "PATH_CREATE_FILE", "PATH_LINK_SOURCE", "PATH_LINK_TARGET", "PATH_OPEN", "FD_READDIR",
  "PATH_READLINK", "PATH_RENAME_SOURCE", "PATH_RENAME_TARGET", "PATH_FILESTAT_GET", "PATH_FILESTAT_SET_SIZE",
  "PATH_FILESTAT_SET_TIMES", "FD_FILESTAT_GET", "FD_FILESTAT_SET_SIZE", "FD_FILESTAT_SET_TIMES", "PATH_SYMLINK",
  "PATH_REMOVE_DIRECTORY", "PATH_UNLINK_FILE", "POLL_FD_READWRITE", "SOCK_SHUTDOWN", "SOCK_ACCEPT"].forEach((n, i) => { R[n] = 1n << BigInt(i); });
const any = (...names) => names.reduce((a, n) => a | R[n], 0n);
const FILE_RIGHTS = any("FD_DATASYNC", "FD_READ", "FD_SEEK", "FD_FDSTAT_SET_FLAGS", "FD_SYNC", "FD_TELL", "FD_WRITE", "FD_ADVISE",
  "FD_ALLOCATE", "FD_FILESTAT_GET", "FD_FILESTAT_SET_SIZE", "FD_FILESTAT_SET_TIMES", "POLL_FD_READWRITE");
const DIR_RIGHTS = any("FD_FDSTAT_SET_FLAGS", "FD_SYNC", "FD_ADVISE", "PATH_CREATE_DIRECTORY", "PATH_CREATE_FILE", "PATH_LINK_SOURCE",
  "PATH_LINK_TARGET", "PATH_OPEN", "FD_READDIR", "PATH_READLINK", "PATH_RENAME_SOURCE", "PATH_RENAME_TARGET", "PATH_FILESTAT_GET",
  "PATH_FILESTAT_SET_SIZE", "PATH_FILESTAT_SET_TIMES", "FD_FILESTAT_GET", "FD_FILESTAT_SET_TIMES", "PATH_SYMLINK",
  "PATH_REMOVE_DIRECTORY", "PATH_UNLINK_FILE");
const STDIO_RIGHTS = any("FD_READ", "FD_WRITE", "FD_FDSTAT_SET_FLAGS", "FD_FILESTAT_GET", "POLL_FD_READWRITE");

class Exit { constructor(code) { this.code = code; } }
class MemoryLimit {}
class Errno { constructor(code) { this.code = code; } }
const fail = (code) => { throw new Errno(code); };

self.onmessage = async (event) => {
  const { module: moduleURL, args, env, stdin, cwd, memoryLimitMB, preopens, fuel } = event.data;
  const out = { log: "", error: "" };
  const flush = (stream, final) => {
    const lines = out[stream].split("\n");
    out[stream] = final ? "" : lines.pop();
    for (const line of final ? lines.filter((l, i) => l !== "" || i < lines.length - 1) : lines) postMessage({ type: "console", level: stream, text: line });
  };
  const now = () => BigInt(Math.round((performance.timeOrigin + performance.now()) * 1e6));

  // MARK: The tree

  let nextIno = 1n;
  const nodes = new Map();
  function node(type, extra) {
    const t = now(), n = { ino: nextIno++, type, atim: t, mtim: t, ctim: t, nlink: 1, ...extra };
    if (type === T.DIR) n.entries = new Map();
    nodes.set(n.ino, n);
    return n;
  }
  const root = node(T.DIR, { parent: null });
  root.parent = root;
  const originalFiles = new Map(); // project path → node, as loaded
  const originalDirs = new Set([""]);

  function mkdirs(path) {
    let dir = root;
    if (!path) return dir;
    for (const part of path.split("/")) {
      let next = dir.entries.get(part);
      if (!next) { next = node(T.DIR, { parent: dir }); dir.entries.set(part, next); }
      dir = next;
    }
    return dir;
  }
  const [manifest, dirList] = await Promise.all([
    (await fetch(base + "__omnie/manifest.json")).json(), (await fetch(base + "__omnie/dirs.json")).json()]);
  for (const d of dirList) { mkdirs(d); originalDirs.add(d); }
  for (const p of manifest) {
    const slash = p.lastIndexOf("/");
    const dir = mkdirs(slash < 0 ? "" : p.slice(0, slash));
    const file = node(T.FILE, { source: p, data: null });
    dir.entries.set(p.slice(slash + 1), file);
    originalFiles.set(p, file);
  }

  function data(n) {
    if (n.data) return n.data;
    // Synchronous, from this worker: WASI calls are synchronous.
    const xhr = new XMLHttpRequest();
    xhr.open("GET", base + "__omnie/source/" + n.source.split("/").map(encodeURIComponent).join("/"), false);
    xhr.overrideMimeType("text/plain; charset=x-user-defined");
    xhr.send();
    if (xhr.status !== 200) fail(E.IO);
    const text = xhr.responseText, bytes = new Uint8Array(text.length);
    for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i) & 0xff;
    n.data = bytes;
    return bytes;
  }
  function setData(n, bytes) { n.data = bytes; n.dirty = true; n.mtim = n.ctim = now(); }
  const size = (n) => (n.type === T.FILE ? data(n).length : n.type === T.SYMLINK ? encoder.encode(n.target).length : 0);

  /// Resolves `path` from directory node `start`, never above it. Returns { dir, name, node }:
  /// `node` is null when only the last component is missing. `follow` follows a final symlink.
  function resolve(start, path, follow, depth = 0) {
    if (depth > 40) fail(E.LOOP);
    if (path === "") fail(E.NOENT);
    if (path.startsWith("/")) fail(E.NOTCAPABLE);
    const trailing = path.endsWith("/");
    const parts = path.split("/").filter((p) => p !== "");
    const stack = [start];
    for (let i = 0; i < parts.length; i++) {
      const part = parts[i], last = i === parts.length - 1, dir = stack[stack.length - 1];
      if (part === ".") { if (last) return { dir: dir.parent, name: ".", node: dir, self: true }; continue; }
      if (part === "..") {
        if (stack.length === 1) fail(E.NOTCAPABLE);
        stack.pop();
        if (last) { const d = stack[stack.length - 1]; return { dir: d.parent, name: "..", node: d, self: true }; }
        continue;
      }
      if (dir.type !== T.DIR) fail(E.NOTDIR);
      const child = dir.entries.get(part);
      if (!child) {
        if (!last) fail(E.NOENT);
        return { dir, name: part, node: null, trailing };
      }
      if (child.type === T.SYMLINK && (!last || follow || trailing)) {
        if (child.target.startsWith("/")) fail(E.NOTCAPABLE);
        const rest = parts.slice(i + 1).join("/") + (trailing ? "/" : "");
        const target = child.target + (rest ? "/" + rest : "");
        // Resolve the link from its own directory, keeping what's above it reachable.
        const inner = resolveFrom(stack, target, follow, depth + 1);
        return inner;
      }
      if (last) {
        if (trailing && child.type !== T.DIR) fail(E.NOTDIR);
        return { dir, name: part, node: child, trailing };
      }
      stack.push(child);
    }
    const d = stack[stack.length - 1];
    return { dir: d.parent, name: ".", node: d, self: true };
  }
  function resolveFrom(stack, path, follow, depth) {
    // Re-run from the bottom of the stack so ".." in a link target stays inside the start dir.
    let walked = [];
    for (let i = 1; i < stack.length; i++) walked.push(nameOf(stack[i - 1], stack[i]));
    return resolve(stack[0], [...walked, path].join("/"), follow, depth);
  }
  const nameOf = (dir, child) => { for (const [k, v] of dir.entries) if (v === child) return k; return "."; };

  // MARK: Descriptors

  const fds = new Map();
  fds.set(0, { kind: "stdin", pos: 0, data: encoder.encode(stdin ?? ""), base: STDIO_RIGHTS, inheriting: 0n, flags: 0 });
  fds.set(1, { kind: "stdout", stream: "log", base: STDIO_RIGHTS, inheriting: 0n, flags: 0 });
  fds.set(2, { kind: "stderr", stream: "error", base: STDIO_RIGHTS, inheriting: 0n, flags: 0 });
  const preopen = (name, n) => ({ kind: "dir", node: n, preopen: name, base: DIR_RIGHTS, inheriting: DIR_RIGHTS | FILE_RIGHTS, flags: 0, cookie: 0 });
  // wasi-libc joins relative paths onto "/" before picking a preopen, so with a working directory
  // only "." is offered (as `wasmtime --dir .` does). "root": just "/" (wasi-testsuite's way).
  if (preopens === "root") fds.set(3, preopen("/", root));
  else if (preopens === "none") { /* nothing */ } else {
    fds.set(3, preopen(".", cwd ? resolve(root, cwd, true).node ?? root : root));
    if (!cwd) fds.set(4, preopen("/", root));
  }
  const openFd = (entry) => { let fd = 3; while (fds.has(fd)) fd++; fds.set(fd, entry); return fd; };
  function get(fd, right, kinds) {
    const d = fds.get(fd);
    if (!d) fail(E.BADF);
    if (kinds && !kinds.includes(d.kind)) fail(d.kind === "dir" ? E.ISDIR : E.BADF);
    if (right && !(d.base & right)) fail(E.NOTCAPABLE);
    return d;
  }
  const dirOf = (fd, right) => {
    const d = fds.get(fd);
    if (!d) fail(E.BADF);
    if (d.kind !== "dir") fail(E.NOTDIR);
    if (right && !(d.base & right)) fail(E.NOTCAPABLE);
    return d;
  };

  let memory;
  const view = () => new DataView(memory.buffer);
  const bytes = () => new Uint8Array(memory.buffer);
  const str = (ptr, len) => decoder.decode(bytes().slice(ptr, ptr + len));
  const limit = (memoryLimitMB ?? 1024) * 1024 * 1024;
  let memoryPeak = 0;
  const check = () => {
    if (!memory) return;
    memoryPeak = Math.max(memoryPeak, memory.buffer.byteLength);
    if (memory.buffer.byteLength > limit) throw new MemoryLimit();
  };

  function filestat(ptr, n) {
    const v = view();
    v.setBigUint64(ptr, 1n, true); v.setBigUint64(ptr + 8, n ? n.ino : 0n, true);
    v.setUint8(ptr + 16, n ? n.type : T.CHAR); v.setBigUint64(ptr + 24, BigInt(n ? n.nlink : 1), true);
    v.setBigUint64(ptr + 32, BigInt(n ? size(n) : 0), true);
    v.setBigUint64(ptr + 40, n ? n.atim : 0n, true); v.setBigUint64(ptr + 48, n ? n.mtim : 0n, true); v.setBigUint64(ptr + 56, n ? n.ctim : 0n, true);
  }
  function setTimes(n, atim, mtim, flags) {
    if ((flags & 1 && flags & 2) || (flags & 4 && flags & 8) || flags > 15) fail(E.INVAL);
    const t = now();
    if (flags & 1) n.atim = atim; else if (flags & 2) n.atim = t;
    if (flags & 4) n.mtim = mtim; else if (flags & 8) n.mtim = t;
  }
  function iovecs(ptr, count) {
    const v = view(), list = [];
    for (let i = 0; i < count; i++) list.push([v.getUint32(ptr + i * 8, true), v.getUint32(ptr + i * 8 + 4, true)]);
    return list;
  }
  function putStrings(list, ptrs, buf) {
    const v = view(), b = bytes();
    for (const s of list) { v.setUint32(ptrs, buf, true); ptrs += 4; const e = encoder.encode(s); b.set(e, buf); b[buf + e.length] = 0; buf += e.length + 1; }
  }
  const envList = Object.entries(env ?? {}).map(([k, v]) => `${k}=${v}`);
  function unlinkEntry(dir, name) {
    const n = dir.entries.get(name);
    dir.entries.delete(name);
    n.nlink--; n.ctim = now();
    dir.mtim = now();
  }

  const wasi = {
    args_sizes_get(c, s) { view().setUint32(c, args.length, true); view().setUint32(s, args.reduce((n, a) => n + encoder.encode(a).length + 1, 0), true); },
    args_get(p, b) { putStrings(args, p, b); },
    environ_sizes_get(c, s) { view().setUint32(c, envList.length, true); view().setUint32(s, envList.reduce((n, a) => n + encoder.encode(a).length + 1, 0), true); },
    environ_get(p, b) { putStrings(envList, p, b); },
    clock_res_get(id, ptr) { if (id > 3) fail(E.INVAL); view().setBigUint64(ptr, 1000n, true); },
    clock_time_get(id, precision, ptr) {
      if (id > 3) fail(E.INVAL);
      view().setBigUint64(ptr, id === 0 ? now() : BigInt(Math.round(performance.now() * 1e6)), true);
    },
    fd_advise(fd, offset, len, advice) { const d = get(fd, R.FD_ADVISE); if (d.kind === "dir") fail(E.BADF); if (advice > 5) fail(E.INVAL); },
    fd_allocate(fd, offset, len) {
      const d = get(fd, R.FD_ALLOCATE, ["file"]);
      const end = Number(offset + len), old = data(d.node);
      if (end > old.length) { const next = new Uint8Array(end); next.set(old); setData(d.node, next); }
    },
    fd_datasync(fd) { get(fd, R.FD_DATASYNC); },
    fd_sync(fd) { get(fd, R.FD_SYNC); },
    fd_close(fd) { get(fd); fds.delete(fd); },
    fd_fdstat_get(fd, ptr) {
      const d = get(fd), v = view();
      v.setUint8(ptr, d.kind === "dir" ? T.DIR : d.kind === "file" ? T.FILE : T.CHAR);
      v.setUint16(ptr + 2, d.flags, true);
      v.setBigUint64(ptr + 8, d.base, true); v.setBigUint64(ptr + 16, d.inheriting, true);
    },
    fd_fdstat_set_flags(fd, flags) { const d = get(fd, R.FD_FDSTAT_SET_FLAGS); d.flags = flags; },
    fd_fdstat_set_rights(fd, base, inheriting) {
      const d = get(fd);
      if ((base & ~d.base) || (inheriting & ~d.inheriting)) fail(E.NOTCAPABLE);
      d.base = base; d.inheriting = inheriting;
    },
    fd_filestat_get(fd, ptr) { const d = get(fd, R.FD_FILESTAT_GET); filestat(ptr, d.node ?? null); },
    fd_filestat_set_size(fd, sz) {
      const d = get(fd, R.FD_FILESTAT_SET_SIZE, ["file"]);
      const old = data(d.node), next = new Uint8Array(Number(sz)); next.set(old.subarray(0, next.length)); setData(d.node, next);
    },
    fd_filestat_set_times(fd, atim, mtim, flags) { const d = get(fd, R.FD_FILESTAT_SET_TIMES); if (!d.node) fail(E.BADF); setTimes(d.node, atim, mtim, flags); },
    fd_prestat_get(fd, ptr) {
      const d = get(fd); if (!d.preopen) fail(E.BADF);
      view().setUint8(ptr, 0); view().setUint32(ptr + 4, encoder.encode(d.preopen).length, true);
    },
    fd_prestat_dir_name(fd, ptr, len) {
      const d = get(fd); if (!d.preopen) fail(E.BADF);
      const name = encoder.encode(d.preopen); if (len < name.length) fail(E.NAMETOOLONG);
      bytes().set(name, ptr);
    },
    fd_read(fd, iovs, count, ptr) { readInto(fd, iovs, count, ptr, null); },
    fd_pread(fd, iovs, count, offset, ptr) { readInto(fd, iovs, count, ptr, Number(offset)); },
    fd_write(fd, iovs, count, ptr) { writeFrom(fd, iovs, count, ptr, null); },
    fd_pwrite(fd, iovs, count, offset, ptr) { writeFrom(fd, iovs, count, ptr, Number(offset)); },
    fd_seek(fd, offset, whence, ptr) {
      const d = get(fd);
      if (d.kind === "dir") fail(E.ISDIR);
      if (d.kind !== "file") fail(E.SPIPE);
      if (!(d.base & (R.FD_SEEK | R.FD_TELL))) fail(E.NOTCAPABLE);
      if (whence > 2) fail(E.INVAL);
      const off = Number(offset), next = whence === 0 ? off : whence === 1 ? d.pos + off : size(d.node) + off;
      if (next < 0) fail(E.INVAL);
      d.pos = next; view().setBigUint64(ptr, BigInt(next), true);
    },
    fd_tell(fd, ptr) { const d = get(fd, R.FD_TELL, ["file"]); view().setBigUint64(ptr, BigInt(d.pos), true); },
    fd_readdir(fd, buf, len, cookie, usedPtr) {
      const d = get(fd, R.FD_READDIR, ["dir"]), dir = d.node;
      const entries = [[".", dir], ["..", dir.parent], ...[...dir.entries.entries()].sort((a, b) => (a[0] < b[0] ? -1 : 1))];
      const b = bytes();
      let used = 0;
      for (let i = Number(cookie); i < entries.length && used < len; i++) {
        const [name, n] = entries[i], encoded = encoder.encode(name);
        const record = new Uint8Array(24 + encoded.length), rv = new DataView(record.buffer);
        rv.setBigUint64(0, BigInt(i + 1), true); rv.setBigUint64(8, n.ino, true);
        rv.setUint32(16, encoded.length, true); rv.setUint8(20, n.type); record.set(encoded, 24);
        const take = Math.min(record.length, len - used);
        b.set(record.subarray(0, take), buf + used); used += take;
      }
      view().setUint32(usedPtr, used, true);
    },
    fd_renumber(from, to) {
      const d = get(from); get(to);
      fds.set(to, d); fds.delete(from);
    },
    path_create_directory(fd, ptr, len) {
      const d = dirOf(fd, R.PATH_CREATE_DIRECTORY), r = resolve(d.node, str(ptr, len), false);
      if (r.node) fail(E.EXIST);
      r.dir.entries.set(r.name, node(T.DIR, { parent: r.dir })); r.dir.mtim = now();
    },
    path_filestat_get(fd, flags, ptr, len, out) {
      const d = dirOf(fd, R.PATH_FILESTAT_GET), r = resolve(d.node, str(ptr, len), !!(flags & 1));
      if (!r.node) fail(E.NOENT);
      filestat(out, r.node);
    },
    path_filestat_set_times(fd, flags, ptr, len, atim, mtim, fst) {
      const d = dirOf(fd, R.PATH_FILESTAT_SET_TIMES), r = resolve(d.node, str(ptr, len), !!(flags & 1));
      if (!r.node) fail(E.NOENT);
      setTimes(r.node, atim, mtim, fst);
    },
    path_link(fd, flags, ptr, len, fd2, ptr2, len2) {
      const a = dirOf(fd, R.PATH_LINK_SOURCE), b = dirOf(fd2, R.PATH_LINK_TARGET);
      const from = resolve(a.node, str(ptr, len), !!(flags & 1)), to = resolve(b.node, str(ptr2, len2), false);
      if (!from.node) fail(E.NOENT);
      if (to.node) fail(E.EXIST);
      if (from.node.type === T.DIR) fail(E.PERM);
      if (to.trailing) fail(E.NOENT);
      to.dir.entries.set(to.name, from.node); from.node.nlink++; from.node.ctim = now();
    },
    path_symlink(ptr, len, fd, ptr2, len2) {
      const target = str(ptr, len), d = dirOf(fd, R.PATH_SYMLINK), r = resolve(d.node, str(ptr2, len2), false);
      if (target.startsWith("/")) fail(E.NOTCAPABLE);
      if (r.node) fail(E.EXIST);
      if (r.trailing) fail(E.NOENT);
      r.dir.entries.set(r.name, node(T.SYMLINK, { target }));
    },
    path_readlink(fd, ptr, len, buf, bufLen, usedPtr) {
      const d = dirOf(fd, R.PATH_READLINK), r = resolve(d.node, str(ptr, len), false);
      if (!r.node) fail(E.NOENT);
      if (r.node.type !== T.SYMLINK) fail(E.INVAL);
      const target = encoder.encode(r.node.target), n = Math.min(target.length, bufLen);
      bytes().set(target.subarray(0, n), buf); view().setUint32(usedPtr, n, true);
    },
    path_open(fd, dirflags, ptr, len, oflags, base, inheriting, fdflags, outPtr) {
      const d = dirOf(fd, R.PATH_OPEN);
      const create = oflags & 1, directory = oflags & 2, exclusive = oflags & 4, truncate = oflags & 8;
      const r = resolve(d.node, str(ptr, len), !!(dirflags & 1) && !(create && exclusive));
      let n = r.node;
      if (n && n.type === T.SYMLINK) fail(E.LOOP);
      if (create && exclusive && n) fail(E.EXIST);
      if (!n) {
        if (!create || directory) fail(E.NOENT);
        if (r.trailing) fail(E.ISDIR);
        if (!(d.base & R.PATH_CREATE_FILE)) fail(E.NOTCAPABLE);
        n = node(T.FILE, { data: new Uint8Array(0), dirty: true });
        r.dir.entries.set(r.name, n); r.dir.mtim = now();
      }
      if (directory && n.type !== T.DIR) fail(E.NOTDIR);
      const wantsWrite = base & (R.FD_WRITE | R.FD_ALLOCATE | R.FD_FILESTAT_SET_SIZE | R.FD_DATASYNC);
      if (n.type === T.DIR) {
        if (wantsWrite & R.FD_WRITE || truncate) fail(E.ISDIR);
        fds.set(outPtr, null); fds.delete(outPtr);
        view().setUint32(outPtr, openFd({ kind: "dir", node: n, base: base & d.inheriting & DIR_RIGHTS, inheriting: inheriting & d.inheriting, flags: fdflags, cookie: 0 }), true);
        return;
      }
      if (truncate) {
        if (!(d.base & R.PATH_FILESTAT_SET_SIZE)) fail(E.NOTCAPABLE);
        setData(n, new Uint8Array(0));
      }
      view().setUint32(outPtr, openFd({ kind: "file", node: n, pos: 0, base: base & d.inheriting & FILE_RIGHTS, inheriting: inheriting & d.inheriting, flags: fdflags }), true);
    },
    path_remove_directory(fd, ptr, len) {
      const d = dirOf(fd, R.PATH_REMOVE_DIRECTORY), r = resolve(d.node, str(ptr, len), false);
      if (r.self) fail(r.name === "." ? E.INVAL : E.NOTEMPTY);
      if (!r.node) fail(E.NOENT);
      if (r.node.type !== T.DIR) fail(E.NOTDIR);
      if (r.node.entries.size) fail(E.NOTEMPTY);
      unlinkEntry(r.dir, r.name);
    },
    path_rename(fd, ptr, len, fd2, ptr2, len2) {
      const a = dirOf(fd, R.PATH_RENAME_SOURCE), b = dirOf(fd2, R.PATH_RENAME_TARGET);
      const from = resolve(a.node, str(ptr, len), false), to = resolve(b.node, str(ptr2, len2), false);
      if (!from.node || from.self) fail(from.self ? E.INVAL : E.NOENT);
      if (to.self) fail(E.INVAL);
      const n = from.node;
      if (n.type !== T.DIR && (from.trailing || to.trailing)) fail(E.NOTDIR);
      if (to.node) {
        if (to.node === n) return;
        if (n.type === T.DIR && to.node.type !== T.DIR) fail(E.NOTDIR);
        if (n.type !== T.DIR && to.node.type === T.DIR) fail(E.ISDIR);
        if (to.node.type === T.DIR && to.node.entries.size) fail(E.NOTEMPTY);
      }
      // A directory can't move inside itself.
      for (let p = to.dir; ; p = p.parent) { if (p === n) fail(E.INVAL); if (p === p.parent) break; }
      if (to.node) unlinkEntry(to.dir, to.name);
      from.dir.entries.delete(from.name);
      to.dir.entries.set(to.name, n);
      if (n.type === T.DIR) n.parent = to.dir;
      n.ctim = now(); from.dir.mtim = to.dir.mtim = now();
    },
    path_unlink_file(fd, ptr, len) {
      const d = dirOf(fd, R.PATH_UNLINK_FILE), r = resolve(d.node, str(ptr, len), false);
      if (!r.node) fail(E.NOENT);
      if (r.node.type === T.DIR) fail(E.ISDIR);
      if (r.trailing) fail(E.NOTDIR);
      unlinkEntry(r.dir, r.name);
    },
    poll_oneoff(inPtr, outPtr, count, neventsPtr) {
      if (count === 0) fail(E.INVAL);
      // Clock subscriptions sleep (busy-waiting: no shared memory here); stdio is always ready.
      const v = view();
      let wait = Infinity, events = 0, ready = false;
      const subs = [];
      for (let i = 0; i < count; i++) {
        const s = inPtr + i * 48, tag = v.getUint8(s + 8);
        subs.push({ s, tag, fd: v.getUint32(s + 16, true) });
        if (tag === 0) {
          const timeout = Number(v.getBigUint64(s + 24, true)) / 1e6, absolute = v.getUint16(s + 40, true) & 1;
          wait = Math.min(wait, absolute ? timeout - (performance.timeOrigin + performance.now()) : timeout);
        } else ready = true;
      }
      if (!ready && wait > 0 && wait !== Infinity) { const until = performance.now() + Math.min(wait, 10000); while (performance.now() < until) { /* sleep */ } }
      for (const { s, tag, fd } of subs) {
        if (ready && tag === 0) continue;
        const e = outPtr + events * 32;
        v.setBigUint64(e, v.getBigUint64(s, true), true); v.setUint8(e + 10, tag);
        let error = E.SUCCESS, nbytes = 0n;
        if (tag !== 0) {
          const d = fds.get(fd);
          if (!d) error = E.BADF;
          else if (tag === 1 && d.kind === "stdin") nbytes = BigInt(d.data.length - d.pos);
          else if (d.kind === "file") nbytes = BigInt(Math.max(0, size(d.node) - d.pos));
        }
        v.setUint16(e + 8, error, true); v.setBigUint64(e + 16, nbytes, true); v.setUint16(e + 24, 0, true);
        events++;
      }
      v.setUint32(neventsPtr, events, true);
    },
    proc_exit(code) { throw new Exit(code); },
    proc_raise() { fail(E.NOSYS); },
    sched_yield() {},
    random_get(ptr, len) { for (let i = 0; i < len; i += 65536) crypto.getRandomValues(bytes().subarray(ptr + i, ptr + Math.min(len, i + 65536))); },
    sock_accept(fd) { get(fd); fail(E.NOTSOCK); },
    sock_recv(fd) { get(fd); fail(E.NOTSOCK); },
    sock_send(fd) { get(fd); fail(E.NOTSOCK); },
    sock_shutdown(fd) { get(fd); fail(E.NOTSOCK); },
  };

  function readInto(fd, iovs, count, nreadPtr, offset) {
    const d = get(fd, R.FD_READ, ["stdin", "file"]);
    if (offset !== null && d.kind !== "file") fail(E.SPIPE);
    const src = d.kind === "stdin" ? d.data : data(d.node);
    let pos = offset ?? d.pos, total = 0;
    const b = bytes();
    for (const [ptr, len] of iovecs(iovs, count)) {
      const chunk = src.subarray(pos, pos + len); b.set(chunk, ptr); pos += chunk.length; total += chunk.length;
      if (chunk.length < len) break;
    }
    if (offset === null) d.pos = pos;
    view().setUint32(nreadPtr, total, true);
  }

  function writeFrom(fd, iovs, count, nwrittenPtr, offset) {
    const d = get(fd, R.FD_WRITE, ["stdout", "stderr", "file"]);
    if (offset !== null && d.kind !== "file") fail(E.SPIPE);
    const parts = iovecs(iovs, count).map(([ptr, len]) => bytes().slice(ptr, ptr + len));
    const total = parts.reduce((n, p) => n + p.length, 0);
    if (d.kind === "file") {
      const old = data(d.node);
      let pos = d.flags & 1 && offset === null ? old.length : offset ?? d.pos;
      const next = new Uint8Array(Math.max(old.length, pos + total)); next.set(old);
      for (const p of parts) { next.set(p, pos); pos += p.length; }
      setData(d.node, next);
      if (offset === null) d.pos = pos;
    } else {
      for (const p of parts) out[d.stream] += decoder.decode(p, { stream: true });
      if (out[d.stream].includes("\n")) flush(d.stream, false);
    }
    view().setUint32(nwrittenPtr, total, true);
  }

  // Every call checks the memory cap and turns errors into errno.
  const imports = {};
  for (const [name, fn] of Object.entries(wasi)) {
    imports[name] = (...a) => {
      check();
      try { fn(...a); return E.SUCCESS; } catch (e) {
        if (e instanceof Errno) return e.code;
        if (e instanceof Exit || e instanceof MemoryLimit) throw e;
        postMessage({ type: "console", level: "error", text: `wasi ${name}: ${e.message}` });
        return E.IO;
      }
    };
  }

  let code = 0, instance = null;
  try {
    const response = await fetch(moduleURL);
    if (!response.ok) throw new Error(`Can't find ${moduleURL.replace(base, "")}`);
    let bytes = await response.arrayBuffer();
    // Fuel: a deterministic budget, spent at every call and loop iteration (wasm-fuel.js).
    let fueled = false;
    if (fuel > 0) {
      const instrumented = self.omnieInstrumentFuel(bytes, fuel);
      if (instrumented) { bytes = instrumented; fueled = true; }
      else postMessage({ type: "console", level: "error", text: "Note: this module couldn't be given a fuel budget; only the timeout limits it." });
    }
    const module = await WebAssembly.compile(bytes);
    const unsupported = WebAssembly.Module.imports(module).filter((i) => i.module !== "wasi_snapshot_preview1" || !(i.name in imports));
    if (unsupported.length) throw new Error("Needs imports RunKit doesn't provide: " + unsupported.map((i) => `${i.module}.${i.name}`).join(", "));
    instance = await WebAssembly.instantiate(module, { wasi_snapshot_preview1: imports });
    memory = instance.exports.memory;
    if (instance.exports._start) instance.exports._start();
    else throw new Error("Not a WASI command (no _start export).");
  } catch (e) {
    if (e instanceof Exit) code = e.code;
    else if (e instanceof MemoryLimit) { code = 137; postMessage({ type: "console", level: "error", text: `Stopped: used more than ${memoryLimitMB ?? 1024} MB of memory.` }); }
    else if (instance?.exports.__omnie_fuel && instance.exports.__omnie_fuel.value < 0n) {
      code = 124; postMessage({ type: "console", level: "error", text: `Stopped: used up its fuel (${fuel.toLocaleString("en")} units).` });
    }
    else { code = 1; postMessage({ type: "console", level: "error", text: e instanceof WebAssembly.RuntimeError ? `wasm trap: ${e.message}` : String(e.message ?? e) }); }
  }
  flush("log", true); flush("error", true);

  // What changed, against the tree as loaded: files to write (new, changed, moved or linked),
  // files and directories gone, directories made. Symlinks aren't saved.
  const finalFiles = new Map(), finalDirs = new Set([""]);
  let symlinks = 0;
  const walk = (dir, prefix) => {
    for (const [name, n] of dir.entries) {
      const p = prefix ? prefix + "/" + name : name;
      if (n.type === T.DIR) { finalDirs.add(p); walk(n, p); } else if (n.type === T.FILE) finalFiles.set(p, n); else symlinks++;
    }
  };
  walk(root, "");
  const toBase64 = (u8) => { let s = ""; for (let i = 0; i < u8.length; i += 32768) s += String.fromCharCode(...u8.subarray(i, i + 32768)); return btoa(s); };
  const writes = {};
  for (const [p, n] of finalFiles) if (n.dirty || originalFiles.get(p) !== n) writes[p] = toBase64(data(n));
  if (symlinks) postMessage({ type: "console", level: "error", text: `Note: ${symlinks} symlink${symlinks === 1 ? "" : "s"} the program made weren't saved.` });
  if (memory) memoryPeak = Math.max(memoryPeak, memory.buffer.byteLength);
  const left = instance?.exports.__omnie_fuel?.value;
  postMessage({
    type: "wasiExit", code, writes, memoryPeak, fuelUsed: typeof left === "bigint" ? Number(BigInt(fuel) - (left < 0n ? 0n : left)) : null,
    deletes: [...originalFiles.keys()].filter((p) => !finalFiles.has(p)),
    dirs: [...finalDirs].filter((d) => d && !originalDirs.has(d)),
    removedDirs: [...originalDirs].filter((d) => d && !finalDirs.has(d)),
  });
  postMessage({ type: "done" });
};

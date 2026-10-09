// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
// Fuel for WASI programs (PLAN.md §8: fuel limits on every run): rewrites a module so every
// function entry and loop iteration spends one unit from a counter, and traps when it's spent.
// The counter is a global appended to the module (exported as "__omnie_fuel"), so no existing
// function or global index moves; only function bodies change. Returns null if the module uses
// an instruction this decoder doesn't know, and the caller runs it without fuel.

class Reader {
  constructor(bytes, pos = 0) { this.b = bytes; this.p = pos; }
  byte() { return this.b[this.p++]; }
  u32() { let r = 0, s = 0, x; do { x = this.b[this.p++]; r |= (x & 0x7f) << s; s += 7; } while (x & 0x80); return r >>> 0; }
  skipLEB() { while (this.b[this.p++] & 0x80); }
  skip(n) { this.p += n; }
}

const uleb = (n) => { const out = []; do { let b = n & 0x7f; n >>>= 7; if (n) b |= 0x80; out.push(b); } while (n); return out; };
const sleb64 = (v) => { // BigInt
  const out = [];
  while (true) {
    const b = Number(v & 0x7fn); v >>= 7n;
    if ((v === 0n && !(b & 0x40)) || (v === -1n && (b & 0x40))) { out.push(b); return out; }
    out.push(b | 0x80);
  }
};

/// Skips one instruction's immediates (the opcode has been read). Throws on unknown opcodes.
function skipImmediates(r, op) {
  if (op === 0x02 || op === 0x03 || op === 0x04) { // block, loop, if: blocktype
    const t = r.b[r.p];
    if (t === 0x40 || t === 0x7f || t === 0x7e || t === 0x7d || t === 0x7c || t === 0x7b || t === 0x70 || t === 0x6f) r.p++; else r.skipLEB();
    return;
  }
  if (op === 0x0c || op === 0x0d) return r.skipLEB(); // br, br_if
  if (op === 0x0e) { const n = r.u32(); for (let i = 0; i <= n; i++) r.skipLEB(); return; } // br_table
  if (op === 0x10 || op === 0x12) return r.skipLEB(); // call, return_call
  if (op === 0x11 || op === 0x13) { r.skipLEB(); r.skipLEB(); return; } // call_indirect
  if (op >= 0x20 && op <= 0x26) return r.skipLEB(); // local/global/table get/set/tee
  if (op >= 0x28 && op <= 0x3e) { const align = r.u32(); if (align & 0x40) r.skipLEB(); r.skipLEB(); return; } // memarg
  if (op === 0x3f || op === 0x40) return r.skipLEB(); // memory.size/grow (memidx)
  if (op === 0x41 || op === 0x42) return r.skipLEB(); // i32/i64.const
  if (op === 0x43) return r.skip(4);
  if (op === 0x44) return r.skip(8);
  if (op === 0xd0) return r.skip(1); // ref.null
  if (op === 0xd2) return r.skipLEB(); // ref.func
  if (op === 0x1c) { const n = r.u32(); r.skip(n); return; } // select t*
  if (op === 0xfc) {
    const sub = r.u32();
    if (sub <= 7) return;
    if (sub === 8) { r.skipLEB(); r.skipLEB(); return; } // memory.init
    if (sub === 9 || sub === 13 || sub === 15 || sub === 16 || sub === 17) return r.skipLEB();
    if (sub === 10 || sub === 12 || sub === 14) { r.skipLEB(); r.skipLEB(); return; } // memory.copy, table.init, table.copy
    if (sub === 11) return r.skipLEB(); // memory.fill
    throw new Error("0xfc " + sub);
  }
  if (op === 0xfd) {
    const sub = r.u32();
    const memarg = () => { const align = r.u32(); if (align & 0x40) r.skipLEB(); r.skipLEB(); };
    if (sub <= 11 || sub === 92 || sub === 93) return memarg();
    if (sub >= 84 && sub <= 91) { memarg(); r.skip(1); return; }
    if (sub === 12 || sub === 13) return r.skip(16);
    if (sub >= 21 && sub <= 34) return r.skip(1);
    if (sub <= 275) return;
    throw new Error("0xfd " + sub);
  }
  if (op === 0xfe) {
    const sub = r.u32();
    if (sub === 3) return r.skip(1); // atomic.fence
    const align = r.u32(); if (align & 0x40) r.skipLEB(); r.skipLEB(); return;
  }
  // Everything else has no immediates; reject what isn't a known opcode.
  const plain = (op >= 0x00 && op <= 0x01) || op === 0x05 || op === 0x0b || op === 0x0f || op === 0x1a || op === 0x1b ||
    (op >= 0x45 && op <= 0xc4) || op === 0xd1;
  if (!plain) throw new Error("opcode 0x" + op.toString(16));
}

self.omnieInstrumentFuel = function instrument(input, fuel) {
  try {
    const bytes = new Uint8Array(input);
    if (bytes[0] !== 0 || bytes[1] !== 0x61 || bytes[4] !== 1) return null;
    // Sections, and the counts we need.
    let pos = 8, importedGlobals = 0, definedGlobals = 0, importedFuncs = 0;
    const sections = [];
    while (pos < bytes.length) {
      const id = bytes[pos];
      const r = new Reader(bytes, pos + 1);
      const size = r.u32();
      sections.push({ id, start: pos, body: r.p, end: r.p + size });
      pos = r.p + size;
    }
    const find = (id) => sections.find((s) => s.id === id);
    const imports = find(2);
    if (imports) {
      const r = new Reader(bytes, imports.body);
      for (let n = r.u32(); n > 0; n--) {
        r.skip(r.u32()); r.skip(r.u32());
        const kind = r.byte();
        if (kind === 0) { importedFuncs++; r.skipLEB(); }
        else if (kind === 1) { r.skip(1); const flags = r.u32(); r.skipLEB(); if (flags & 1) r.skipLEB(); }
        else if (kind === 2) { const flags = r.u32(); r.skipLEB(); if (flags & 1) r.skipLEB(); }
        else if (kind === 3) { importedGlobals++; r.skip(2); }
        else return null;
      }
    }
    const globals = find(6);
    if (globals) definedGlobals = new Reader(bytes, globals.body).u32();
    const fuelIndex = importedGlobals + definedGlobals;
    const idx = uleb(fuelIndex);
    // global.get f; i64.const 1; i64.sub; global.tee? (no tee for globals) global.set f;
    // global.get f; i64.const 0; i64.lt_s; if; unreachable; end
    const charge = [0x23, ...idx, 0x42, 0x01, 0x7d, 0x24, ...idx, 0x23, ...idx, 0x42, 0x00, 0x53, 0x04, 0x40, 0x00, 0x0b];

    // New global and export sections.
    const fuelGlobal = [0x7e, 0x01, 0x42, ...sleb64(BigInt(fuel)), 0x0b];
    const out = [];
    // Appends without spreading: JavaScriptCore caps a call's arguments (~65k), which a big
    // function body exceeds.
    const append = (to, from) => { for (let i = 0; i < from.length; i++) to.push(from[i]); };
    const section = (id, payload) => { out.push(id); append(out, uleb(payload.length)); append(out, payload); };
    const withCount = (s, extra) => {
      const r = new Reader(bytes, s.body); const n = r.u32();
      const result = uleb(n + 1); append(result, bytes.subarray(r.p, s.end)); append(result, extra); return result;
    };
    let wroteGlobals = false, wroteExports = false;
    for (const b of bytes.subarray(0, 8)) out.push(b);
    // Section order matters: global (6) before export (7) before code (10).
    const order = [1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 10, 11];
    const emitMissing = (beforeId) => {
      if (!wroteGlobals && (beforeId === undefined || order.indexOf(beforeId) > order.indexOf(6))) { section(6, [0x01, ...fuelGlobal]); wroteGlobals = true; }
      if (!wroteExports && (beforeId === undefined || order.indexOf(beforeId) > order.indexOf(7))) {
        const name = new TextEncoder().encode("__omnie_fuel");
        section(7, [0x01, ...uleb(name.length), ...name, 0x03, ...idx]); wroteExports = true;
      }
    };
    for (const s of sections) {
      if (s.id !== 0) emitMissing(s.id);
      if (s.id === 6) { section(6, withCount(s, fuelGlobal)); wroteGlobals = true; continue; }
      if (s.id === 7) {
        const name = new TextEncoder().encode("__omnie_fuel");
        section(7, withCount(s, [...uleb(name.length), ...name, 0x03, ...idx])); wroteExports = true; continue;
      }
      if (s.id === 10) {
        const r = new Reader(bytes, s.body);
        const count = r.u32();
        const payload = [...uleb(count)];
        for (let f = 0; f < count; f++) {
          const size = r.u32(), bodyEnd = r.p + size;
          const body = [];
          // Locals stay as they are.
          const localsStart = r.p;
          for (let n = r.u32(); n > 0; n--) { r.skipLEB(); r.skip(1); }
          append(body, bytes.subarray(localsStart, r.p));
          append(body, charge); // function entry
          while (r.p < bodyEnd) {
            const opStart = r.p, op = r.byte();
            skipImmediates(r, op);
            append(body, bytes.subarray(opStart, r.p));
            if (op === 0x03) append(body, charge); // each loop iteration
          }
          append(payload, uleb(body.length)); append(payload, body);
        }
        section(10, payload);
        continue;
      }
      for (const b of bytes.subarray(s.start, s.end)) out.push(b);
    }
    emitMissing(undefined);
    return new Uint8Array(out);
  } catch (e) {
    return null;
  }
};

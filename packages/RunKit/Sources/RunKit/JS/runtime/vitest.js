// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
// A small vitest/jest-compatible subset, so a project's own *.test.ts files run on the device.
import { format } from "omnie-run://local/__omnie/runtime/harness.js";

const tests = [];
const stack = [];
let currentFile = "";

export function __collect(file) { currentFile = file; }

function suite() { return stack.length ? stack[stack.length - 1] : null; }

export function describe(name, fn) {
  const parent = suite();
  const node = { name: parent ? `${parent.name} > ${name}` : name, before: [], after: [], parent };
  stack.push(node);
  try { fn(); } finally { stack.pop(); }
}
describe.skip = () => {};
describe.only = describe;

export function it(name, fn, timeout = 5000) {
  const s = suite();
  tests.push({ file: currentFile, name: s ? `${s.name} > ${name}` : name, fn, timeout, suite: s });
}
it.skip = () => {};
it.only = it;
it.todo = () => {};
export const test = it;

export function beforeEach(fn) { (suite() ?? topLevel).before.push(fn); }
export function afterEach(fn) { (suite() ?? topLevel).after.push(fn); }
const topLevel = { before: [], after: [] };

function hooks(s, kind) {
  const chain = [];
  for (let n = s; n; n = n.parent) chain.unshift(n);
  return [...topLevel[kind], ...chain.flatMap((n) => n[kind])];
}

function equal(a, b) {
  if (Object.is(a, b)) return true;
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  const ka = Object.keys(a), kb = Object.keys(b);
  return ka.length === kb.length && ka.every((k) => equal(a[k], b[k]));
}

/// Values in assertion messages: strings quoted, like vitest prints them.
const show = (v) => (typeof v === "string" ? JSON.stringify(v) : format(v));

class AssertionError extends Error { constructor(m) { super(m); this.name = "AssertionError"; } }

export function expect(actual) {
  const make = (negate) => {
    const check = (pass, message) => { if (pass === negate) throw new AssertionError((negate ? "Expected not: " : "") + message); };
    const m = {
      toBe: (e) => check(Object.is(actual, e), `expected ${show(actual)} to be ${show(e)}`),
      toEqual: (e) => check(equal(actual, e), `expected ${show(actual)} to equal ${show(e)}`),
      toStrictEqual: (e) => check(equal(actual, e), `expected ${show(actual)} to equal ${show(e)}`),
      toBeTruthy: () => check(!!actual, `expected ${show(actual)} to be truthy`),
      toBeFalsy: () => check(!actual, `expected ${show(actual)} to be falsy`),
      toBeNull: () => check(actual === null, `expected ${show(actual)} to be null`),
      toBeUndefined: () => check(actual === undefined, `expected ${show(actual)} to be undefined`),
      toBeDefined: () => check(actual !== undefined, `expected a value`),
      toContain: (e) => check(actual?.includes?.(e), `expected ${show(actual)} to contain ${show(e)}`),
      toHaveLength: (n) => check(actual?.length === n, `expected length ${n}, got ${actual?.length}`),
      toBeGreaterThan: (n) => check(actual > n, `expected ${show(actual)} > ${n}`),
      toBeGreaterThanOrEqual: (n) => check(actual >= n, `expected ${show(actual)} >= ${n}`),
      toBeLessThan: (n) => check(actual < n, `expected ${show(actual)} < ${n}`),
      toBeLessThanOrEqual: (n) => check(actual <= n, `expected ${show(actual)} <= ${n}`),
      toBeCloseTo: (n, digits = 2) => check(Math.abs(actual - n) < Math.pow(10, -digits) / 2, `expected ${show(actual)} to be close to ${n}`),
      toMatch: (re) => check(typeof re === "string" ? actual.includes(re) : re.test(actual), `expected ${show(actual)} to match ${re}`),
      toThrow: (match) => {
        let threw = false, error;
        try { actual(); } catch (e) { threw = true; error = e; }
        const ok = threw && (match === undefined || (typeof match === "string" ? String(error?.message).includes(match) : match.test?.(String(error?.message)) ?? true));
        check(ok, threw ? `threw ${show(error)}` : "expected the function to throw");
      },
    };
    return m;
  };
  const matchers = make(false);
  matchers.not = make(true);
  matchers.resolves = new Proxy({}, { get: (_, k) => async (...a) => expect(await actual)[k](...a) });
  matchers.rejects = new Proxy({}, { get: (_, k) => async (...a) => {
    try { await actual; } catch (e) { return expect(() => { throw e; })[k](...a); }
    throw new AssertionError("expected the promise to reject");
  } });
  return matchers;
}

export const vi = {
  fn(impl = () => undefined) {
    const mock = (...args) => { mock.mock.calls.push(args); return impl(...args); };
    mock.mock = { calls: [] };
    return mock;
  },
};

export async function __run(send) {
  for (const t of tests) {
    const start = performance.now();
    try {
      for (const h of hooks(t.suite, "before")) await h();
      await Promise.race([
        Promise.resolve().then(() => t.fn()),
        new Promise((_, reject) => setTimeout(() => reject(new Error(`timed out after ${t.timeout} ms`)), t.timeout)),
      ]);
      for (const h of hooks(t.suite, "after")) await h();
      send({ type: "test", file: t.file, name: t.name, ok: true, ms: Math.round(performance.now() - start) });
    } catch (e) {
      send({ type: "test", file: t.file, name: t.name, ok: false, error: format(e), ms: Math.round(performance.now() - start) });
    }
  }
}

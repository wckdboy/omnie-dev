# SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
# SPDX-License-Identifier: Apache-2.0
"""A small pytest-compatible subset for running a project's tests on the device (RunKit).
Plain asserts, pytest.raises, pytest.approx, pytest.fail, pytest.mark.parametrize; test_*
functions and Test* classes in test_*.py or *_test.py files."""
import ast
import importlib.util
import inspect
import json
import math
import re
import time
import traceback


class _Raises:
    def __init__(self, expected, match=None):
        self.expected, self.match, self.value = expected, match, None

    def __enter__(self):
        return self

    def __exit__(self, kind, value, tb):
        if kind is None:
            raise AssertionError(f"DID NOT RAISE {getattr(self.expected, '__name__', self.expected)}")
        if not issubclass(kind, self.expected):
            return False
        if self.match and not re.search(self.match, str(value)):
            raise AssertionError(f"{value!r} doesn't match {self.match!r}")
        self.value = value
        return True


def raises(expected, match=None):
    return _Raises(expected, match)


class approx:
    def __init__(self, expected, rel=1e-6, abs=1e-12):
        self.expected, self.rel, self.abs = expected, rel, abs

    def __eq__(self, other):
        if isinstance(self.expected, (list, tuple)):
            return len(other) == len(self.expected) and all(approx(e, self.rel, self.abs) == o for e, o in zip(self.expected, other))
        return math.isclose(other, self.expected, rel_tol=self.rel, abs_tol=self.abs)

    def __repr__(self):
        return f"approx({self.expected!r})"


def fail(message=""):
    raise AssertionError(message)


class _Mark:
    @staticmethod
    def parametrize(names, values):
        names = [n.strip() for n in names.split(",")] if isinstance(names, str) else list(names)

        def decorate(fn):
            fn._omnie_params = getattr(fn, "_omnie_params", []) + [(names, list(values))]
            return fn
        return decorate

    def __getattr__(self, _name):  # skip, xfail and friends: accepted, not acted on
        return lambda *a, **k: (lambda fn: fn) if not (len(a) == 1 and callable(a[0])) else a[0]


mark = _Mark()


def _cases(fn):
    cases = [((), {})]
    for names, values in getattr(fn, "_omnie_params", []):
        expanded = []
        for args, kwargs in cases:
            for value in values:
                value = value if isinstance(value, (list, tuple)) and len(names) > 1 else (value,)
                expanded.append((args, {**kwargs, **dict(zip(names, value))}))
        cases = expanded
    return cases


def _explain(line, frame):
    """For `assert a == b`, the values of both sides, read in the test's frame (no assertion
    rewriting here, so this is how a failure shows what went wrong)."""
    try:
        tree = ast.parse(line.strip())
        test = tree.body[0].test if isinstance(tree.body[0], ast.Assert) else None
    except (SyntaxError, IndexError):
        return ""
    if not isinstance(test, ast.Compare) or len(test.comparators) != 1:
        return ""
    def value(node):
        return eval(compile(ast.Expression(node), "<assert>", "eval"), frame.f_globals, frame.f_locals)  # noqa: S307
    try:
        left, right = value(test.left), value(test.comparators[0])
    except Exception:  # noqa: BLE001
        return ""
    op = {ast.Eq: "==", ast.NotEq: "!=", ast.Lt: "<", ast.LtE: "<=", ast.Gt: ">", ast.GtE: ">=", ast.In: "in", ast.NotIn: "not in",
          ast.Is: "is", ast.IsNot: "is not"}.get(type(test.ops[0]), "?")
    parts = [f"assert {left!r} {op} {right!r}"]
    for node, val in ((test.left, left), (test.comparators[0], right)):
        if not isinstance(node, ast.Constant):
            parts.append(f"{ast.unparse(node)} = {val!r}")
    return "\n    ".join(parts)


def _failure(error, path):
    if isinstance(error, AssertionError):
        message = str(error)
        if message:
            return f"AssertionError: {message}"
        tb = error.__traceback__
        frame, line = None, ""
        while tb is not None:
            if tb.tb_frame.f_code.co_filename.endswith(path):
                frame = tb.tb_frame
                line = traceback.extract_tb(tb, limit=1)[0].line or ""
            tb = tb.tb_next
        detail = _explain(line, frame) if frame else ""
        return f"assert failed: {line}" + (f"\n    {detail}" if detail else "")
    return f"{type(error).__name__}: {error}"


def _omnie_run(files):
    results = []
    for path in files:
        try:
            spec = importlib.util.spec_from_file_location(path[:-3].replace("/", "."), path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
        except Exception as e:  # noqa: BLE001
            results.append({"file": path, "name": "(loading the file)", "ok": False, "error": f"{type(e).__name__}: {e}", "ms": 0})
            continue
        tests = []
        for name, value in vars(module).items():
            if name.startswith("test") and inspect.isfunction(value):
                tests.append((name, value))
            elif name.startswith("Test") and inspect.isclass(value):
                for method, fn in vars(value).items():
                    if method.startswith("test") and inspect.isfunction(fn):
                        tests.append((f"{name}.{method}", getattr(value(), method)))
        for name, fn in tests:
            for args, kwargs in _cases(fn):
                label = name + (f"[{', '.join(repr(v) for v in kwargs.values())}]" if kwargs else "")
                start = time.perf_counter()
                try:
                    fn(*args, **kwargs)
                    results.append({"file": path, "name": label, "ok": True, "ms": round((time.perf_counter() - start) * 1000)})
                except BaseException as e:  # noqa: BLE001
                    results.append({"file": path, "name": label, "ok": False, "error": _failure(e, path),
                                    "ms": round((time.perf_counter() - start) * 1000)})
    return json.dumps(results)

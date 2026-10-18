# SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
# SPDX-License-Identifier: Apache-2.0
#
# RunKit's Python debugger (PLAN.md §5.3), run inside Pyodide by python-debug-worker.js. A line
# tracer (sys.settrace) stops at a project breakpoint or while stepping, and blocks on `pause` — a
# synchronous request to the app (Debugger.swift) whose response says what to do. The frame is live
# while it is blocked, so its locals, and an expression evaluated there, are the paused statement's.
import json
import runpy
import sys
import traceback


class _Stop(Exception):
    """Raised in the trace hook to leave the program when the app answers Stop."""


def _rel(path):
    """A frame's co_filename as a project-relative path."""
    text = str(path).replace("\\", "/")
    if text.startswith("/project/"):
        text = text[len("/project/"):]
    elif text.startswith("./"):
        text = text[2:]
    return text


def _format(value):
    if isinstance(value, str):
        return value
    try:
        return repr(value)
    except BaseException:
        return "<unrepresentable>"


def _visible_locals(frame):
    return [{"name": name, "value": _format(value)}
            for name, value in frame.f_locals.items()
            if not (name.startswith("__") and name.endswith("__"))]


def _frames(frame, line):
    """Innermost first; the first frame is where the stop is."""
    out = []
    current = frame
    while current is not None:
        out.append({"file": _rel(current.f_code.co_filename), "line": current.f_lineno,
                    "column": 0, "name": current.f_code.co_name})
        current = current.f_back
    if out:
        out[0]["line"] = line
    return out


def run(spec, pause, files):
    """Runs `spec["entry"]` under the debugger. `pause` takes the JSON stop and returns the app's
    answer as JSON; `files` are the project's files (breakpoints are only in those)."""
    project = {_rel(path) for path in files}
    breakpoints = set()
    conditions = {}
    for breakpoint in spec.get("breakpoints", []):
        key = (_rel(breakpoint["file"]), int(breakpoint["line"]))
        breakpoints.add(key)
        if breakpoint.get("condition"):
            conditions[key] = breakpoint["condition"]

    stepping = {"mode": None, "project_depth": 0}

    def snap(frame, line, reason):
        evaluated = None
        while True:
            payload = {"file": _rel(frame.f_code.co_filename), "line": line, "reason": reason,
                       "stack": _frames(frame, line), "locals": _visible_locals(frame)}
            if evaluated is not None:
                payload["evaluated"] = evaluated
            answer = json.loads(pause(json.dumps(payload)))
            action = answer.get("action", "continue")
            if action == "eval" and isinstance(answer.get("expression"), str):
                expression = answer["expression"]
                try:
                    value = eval(expression, frame.f_globals, frame.f_locals)  # the paused frame's own eval
                    evaluated = {"expression": expression, "result": _format(value)}
                except BaseException as error:
                    evaluated = {"expression": expression, "result": _format(error), "failed": True}
                continue
            if action == "stop":
                raise _Stop()
            if action == "stepInto":
                stepping["mode"] = ("into", stepping["project_depth"])
            elif action == "stepOver":
                stepping["mode"] = ("over", stepping["project_depth"])
            elif action == "stepOut":
                stepping["mode"] = ("out", stepping["project_depth"])
            else:
                stepping["mode"] = None
            return

    def tracer(frame, event, arg):
        file = _rel(frame.f_code.co_filename)
        if event == "call":
            if file not in project:
                return None
            stepping["project_depth"] += 1
            return tracer
        if event == "return":
            stepping["project_depth"] -= 1
            return tracer
        if event != "line" or file not in project:
            return tracer
        mode = stepping["mode"]
        if mode is not None:
            kind, depth = mode
            now = stepping["project_depth"]
            stop = kind == "into" or (kind == "over" and now <= depth) or (kind == "out" and now < depth)
            if stop:
                snap(frame, frame.f_lineno, "step")
            return tracer
        key = (file, frame.f_lineno)
        if key in breakpoints:
            condition = conditions.get(key)
            if condition:
                try:
                    if not eval(condition, frame.f_globals, frame.f_locals):
                        return tracer
                except BaseException:
                    return tracer
            snap(frame, frame.f_lineno, "breakpoint")
        return tracer

    sys.settrace(tracer)
    try:
        runpy.run_path(spec["entry"], run_name="__main__")
    except _Stop:
        pass
    except SystemExit as exit_code:
        if exit_code.code not in (None, 0):
            print(f"Exited with {exit_code.code}", file=sys.stderr)
    except BaseException:
        traceback.print_exc()
        raise SystemExit("failed")
    finally:
        sys.settrace(None)

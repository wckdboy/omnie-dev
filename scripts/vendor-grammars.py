#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
# SPDX-License-Identifier: Apache-2.0
"""Vendors tree-sitter grammars into packages/LangKit from hash-pinned release tarballs.

Copies only what compiles (parser.c, scanner.c, headers), the highlight/injection queries,
and each grammar's LICENSE. Re-run after changing GRAMMARS; the output is committed.
"""
import hashlib
import io
import shutil
import tarfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LANGKIT = ROOT / "packages" / "LangKit"
C_DIR = LANGKIT / "Sources" / "TreeSitterGrammars"
QUERY_DIR = LANGKIT / "Sources" / "LangKit" / "Resources" / "queries"

# name: (github repo, tag, sha256 of the tag tarball, [source dirs], {language: [query files to concatenate]})
GRAMMARS = {
    "javascript": ("tree-sitter/tree-sitter-javascript", "v0.25.0",
                   "9712fc283d3dc01d996d20b6392143445d05867a7aad76fdd723824468428b86",
                   ["src"], {"javascript": ["highlights.scm", "highlights-jsx.scm"], "javascript.injections": ["injections.scm"]}),
    "typescript": ("tree-sitter/tree-sitter-typescript", "v0.23.2",
                   "2c4ce711ae8d1218a3b2f899189298159d672870b5b34dff5d937bed2f3e8983",
                   ["typescript/src", "tsx/src", "common"], {}),
    "json": ("tree-sitter/tree-sitter-json", "v0.24.8",
             "acf6e8362457e819ed8b613f2ad9a0e1b621a77556c296f3abea58f7880a9213",
             ["src"], {"json": ["highlights.scm"]}),
    "python": ("tree-sitter/tree-sitter-python", "v0.25.0",
               "4609a3665a620e117acf795ff01b9e965880f81745f287a16336f4ca86cf270c",
               ["src"], {"python": ["highlights.scm"]}),
    "swift": ("alex-pinkus/tree-sitter-swift", "0.7.4-with-generated-files",
              "bf4d34383638f41cde398f4678dea72cdcda8442c7cfd13944f4bb63e9a96f70",
              ["src"], {"swift": ["highlights.scm"], "swift.injections": ["injections.scm"]}),
    "css": ("tree-sitter/tree-sitter-css", "v0.25.0",
            "03965344d8c0435dc54fb45b281578420bb7db8b99df4d34e7e74105a274cb79",
            ["src"], {"css": ["highlights.scm"]}),
    "html": ("tree-sitter/tree-sitter-html", "v0.23.2",
             "21fa4f2d4dcb890ef12d09f4979a0007814f67f1c7294a9b17b0108a09e45ef7",
             ["src"], {"html": ["highlights.scm"], "html.injections": ["injections.scm"]}),
}

# TypeScript's highlights extend JavaScript's (per tree-sitter-typescript's tree-sitter.json).
COMPOSED = {
    "typescript": [("javascript", "highlights.scm"), ("typescript", "highlights.scm")],
    "tsx": [("javascript", "highlights.scm"), ("javascript", "highlights-jsx.scm"), ("typescript", "highlights.scm")],
}

# Files that are generated or unused and must not be compiled.
SKIP = {"grammar.json", "node-types.json", "parser_abi13.c", "parser_abi14.c"}


def fetch(repo: str, tag: str, sha: str) -> tarfile.TarFile:
    url = f"https://github.com/{repo}/archive/refs/tags/{tag}.tar.gz"
    data = urllib.request.urlopen(url).read()
    digest = hashlib.sha256(data).hexdigest()
    if digest != sha:
        raise SystemExit(f"checksum mismatch for {repo}@{tag}: {digest}")
    return tarfile.open(fileobj=io.BytesIO(data))


def main() -> None:
    # Each grammar's folder goes; include/ (the umbrella header, committed) stays.
    C_DIR.mkdir(parents=True, exist_ok=True)
    for child in C_DIR.iterdir():
        if child.name != "include":
            shutil.rmtree(child, ignore_errors=True) if child.is_dir() else child.unlink()
    shutil.rmtree(QUERY_DIR, ignore_errors=True)
    QUERY_DIR.mkdir(parents=True)
    raw_queries: dict[tuple[str, str], str] = {}

    for name, (repo, tag, sha, dirs, queries) in GRAMMARS.items():
        tar = fetch(repo, tag, sha)
        prefix = tar.getnames()[0].split("/")[0] + "/"
        out = C_DIR / name
        for member in tar.getmembers():
            if not member.isfile():
                continue
            rel = member.name[len(prefix):]
            fname = rel.split("/")[-1]
            wanted = (any(rel.startswith(d + "/") for d in dirs) and fname not in SKIP
                      and (fname.endswith((".c", ".h"))))
            if rel in ("LICENSE", "LICENSE.md", "LICENSE.txt"):
                (out).mkdir(parents=True, exist_ok=True)
                (out / "LICENSE").write_bytes(tar.extractfile(member).read())
            elif wanted:
                dest = out / rel
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(tar.extractfile(member).read())
            elif rel.startswith("queries/") and fname.endswith(".scm"):
                raw_queries[(name, fname)] = tar.extractfile(member).read().decode()
        for target, files in queries.items():
            lang, _, kind = target.partition(".")
            text = "\n".join(raw_queries[(name, f)] for f in files)
            (QUERY_DIR / f"{lang}.{kind or 'highlights'}.scm").write_text(text)
        print(f"vendored {name} {tag}")

    for lang, parts in COMPOSED.items():
        text = "\n".join(raw_queries[p] for p in parts)
        (QUERY_DIR / f"{lang}.highlights.scm").write_text(text)

    # These generated files are gitignored, so they're outside the REUSE scope of this repo; each grammar's
    # upstream LICENSE is copied next to its sources and NOTICE lists them.


if __name__ == "__main__":
    main()

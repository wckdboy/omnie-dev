#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
# SPDX-License-Identifier: Apache-2.0
"""Writes the licence texts of every crate a WASI tool links (from `cargo metadata`) into one file.

    collect-cargo-licenses.py <crate dir> <output file>
"""
import hashlib, json, pathlib, subprocess, sys, urllib.request

# Crates that ship no licence file get the SPDX text (same pinned commit as vendor-runkit.sh,
# checked) under a line naming the crate's authors.
SPDX = "31ba1a50e5397e00a304dbadc76531740e89ee48"
SPDX_SHA256 = {"MIT": "b05785f9f18e6716bab63424b11454513b9943a222595b70411009202fc592b5"}


def spdx_text(license_id):
    if license_id not in SPDX_SHA256:
        sys.exit(f"no pinned SPDX text for {license_id}")
    url = f"https://raw.githubusercontent.com/spdx/license-list-data/{SPDX}/text/{license_id}.txt"
    data = urllib.request.urlopen(url).read()
    if hashlib.sha256(data).hexdigest() != SPDX_SHA256[license_id]:
        sys.exit(f"{url} doesn't match its pinned hash")
    return data.decode()

crate, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
meta = json.loads(subprocess.check_output(
    ["cargo", "metadata", "--format-version", "1", "--locked", "--filter-platform", "wasm32-wasip1"], cwd=crate))
used = {node["id"] for node in meta["resolve"]["nodes"]}
root = meta["resolve"]["root"]
sections = []
for package in sorted(meta["packages"], key=lambda p: p["name"]):
    if package["id"] not in used or package["id"] == root:
        continue
    folder = pathlib.Path(package["manifest_path"]).parent
    texts = [f for f in sorted(folder.iterdir()) if f.is_file() and f.name.upper().startswith(("LICENSE", "LICENCE", "COPYING", "UNLICENSE"))]
    if texts:
        body = "\n".join(f"--- {t.name}\n{t.read_text(errors='replace').strip()}\n" for t in texts)
    else:
        license_id = package["license"].split(" OR ")[0].strip("()")
        authors = ", ".join(package.get("authors") or [package["name"] + " authors"])
        body = f"--- (no licence file in the crate; SPDX {license_id} text)\nCopyright (c) {authors}\n\n{spdx_text(license_id).strip()}\n"
    sections.append(f"=== {package['name']} {package['version']} ({package['license']}) {package.get('repository') or ''}\n{body}")
# Linked into every wasm32-wasip1 binary: Rust's standard library and wasi-libc.
sysroot = pathlib.Path(subprocess.check_output(["rustc", "--print", "sysroot"], text=True).strip())
docs = sysroot / "share/doc/rust"
rust = [f for f in sorted((docs / "licenses").glob("*")) if f.is_file() and f.stem in ("MIT", "Apache-2.0", "LLVM-exception")]
if not rust:
    sys.exit(f"no Rust licence texts in {docs}")
sections.append("=== Rust standard library (MIT OR Apache-2.0) https://github.com/rust-lang/rust\n"
                + "\n".join(f"--- {t.name}\n{t.read_text(errors='replace').strip()}\n" for t in rust))
sections.append("=== wasi-libc (Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT; used under MIT) https://github.com/WebAssembly/wasi-libc\n"
                + f"Copyright (c) wasi-libc contributors\n\n{spdx_text('MIT').strip()}\n")
out.write_text("Licences of the code in this WASI tool.\n\n" + "\n".join(sections))
print(f"{len(sections)} crates' licences in {out}")

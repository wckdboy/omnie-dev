#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
# SPDX-License-Identifier: Apache-2.0
"""Collects the license text of everything the app ships into apps/ipad/Resources/Acknowledgements.json,
which Settings › Acknowledgements shows. BSD, MIT and Apache all require the notices to travel with
binaries, so run this after changing a dependency (it needs a built project: the native deps from
scripts/build-git-deps.sh and the Swift packages resolved by an Xcode build)."""
import importlib.util
import sys
sys.dont_write_bytecode = True  # importing vendor-grammars.py must not leave a __pycache__
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "apps/ipad/Resources/Acknowledgements.json"
CHECKOUTS = ROOT / ".build/dd/SourcePackages/checkouts"
RESOLVED = ROOT / "OmnieDev.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
NATIVE = ROOT / ".build/vendor"

# Swift packages that are only used at build time (macros) and aren't in the binary.
BUILD_ONLY = {"swift-syntax"}


def license_files(folder: Path) -> list[Path]:
    names = sorted(p for p in folder.iterdir()
                   if p.is_file() and p.name.upper().split(".")[0] in {"LICENSE", "COPYING", "NOTICE"})
    if not names:
        sys.exit(f"no license file in {folder}")
    return names


def entry(name: str, version: str, files: list[Path], url: str = "") -> dict:
    text = "\n\n".join(f.read_text(errors="replace").strip() for f in files)
    return {"name": name, "version": version, "url": url, "text": text}


def main() -> None:
    items = []
    versions = {}
    if RESOLVED.exists():
        for pin in json.loads(RESOLVED.read_text())["pins"]:
            versions[pin["identity"]] = (pin["state"].get("version") or pin["state"].get("revision", "")[:12], pin["location"])

    # Native: linked into GitKit's xcframework.
    for name, folder, url in [("libgit2", "libgit2", "https://github.com/libgit2/libgit2"),
                              ("libssh2", "libssh2-1.11.1", "https://libssh2.org"),
                              ("OpenSSL (libcrypto)", "openssl-3.6.5", "https://www.openssl.org")]:
        path = NATIVE / folder
        if not path.exists():
            sys.exit(f"missing {path}; run scripts/build-git-deps.sh")
        version = folder.rsplit("-", 1)[1] if "-" in folder else "1.9.7"
        items.append(entry(name, version, license_files(path), url))

    # Swift packages.
    if not CHECKOUTS.exists():
        sys.exit(f"missing {CHECKOUTS}; build the app once")
    for folder in sorted(CHECKOUTS.iterdir(), key=lambda p: p.name.lower()):
        if folder.name in BUILD_ONLY or not folder.is_dir():
            continue
        version, url = versions.get(folder.name.lower(), ("", ""))
        items.append(entry(folder.name, version, license_files(folder), url))

    # tree-sitter grammars (vendored into LangKit).
    spec = importlib.util.spec_from_file_location("vendor_grammars", ROOT / "scripts/vendor-grammars.py")
    pins = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pins)
    grammars = ROOT / "packages/LangKit/Sources/TreeSitterGrammars"
    for folder in sorted(p for p in grammars.iterdir() if (p / "LICENSE").exists()):
        repo, tag = pins.GRAMMARS[folder.name][:2]
        items.append(entry(f"tree-sitter-{folder.name}", tag.lstrip("v"), [folder / "LICENSE"], f"https://github.com/{repo}"))

    # RunKit's TypeScript transpiler (scripts/vendor-runkit.sh).
    sucrase = ROOT / "packages/RunKit/Sources/RunKit/JS/sucrase-LICENSE.txt"
    if not sucrase.exists():
        sys.exit(f"missing {sucrase}; run scripts/vendor-runkit.sh")
    items.append(entry("Sucrase", "3.35.1", [sucrase], "https://github.com/alangpierce/sucrase"))
    items.append(entry("three.js", "0.186.1", [ROOT / "packages/RunKit/Sources/RunKit/JS/packages/three/LICENSE"], "https://threejs.org"))
    packages = ROOT / "packages/RunKit/Sources/RunKit/JS/packages"
    items.append(entry("marked", "18.1.0", [packages / "marked/LICENSE"], "https://marked.js.org"))
    items.append(entry("Mermaid", "12.1.0", [packages / "mermaid/LICENSE"], "https://mermaid.js.org"))
    pyodide = ROOT / "packages/RunKit/Sources/RunKit/JS/pyodide"
    items.append(entry("Pyodide", "314.0.7", [pyodide / "MPL-2.0.txt"], "https://github.com/pyodide/pyodide"))
    items.append(entry("CPython (in Pyodide)", "3.14", [pyodide / "PSF-2.0.txt"], "https://www.python.org"))

    # The WASI spike's runtime and tests, when vendored into this build.
    spike = ROOT / "apps/ipad/Resources/WASISpike"
    if spike.exists():
        items.append(entry("browser_wasi_shim", "0.4.2", [spike / "shim/LICENSE-MIT", spike / "shim/LICENSE-APACHE"],
                           "https://github.com/bjorn3/browser_wasi_shim"))
        items.append(entry("wasi-testsuite", "", [spike / "LICENSE-wasi-testsuite"],
                           "https://github.com/WebAssembly/wasi-testsuite"))

    items.sort(key=lambda i: i["name"].lower())
    OUT.write_text(json.dumps(items, indent=1, ensure_ascii=False) + "\n")
    print(f"wrote {len(items)} acknowledgements to {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()

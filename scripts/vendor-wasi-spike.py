#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
# SPDX-License-Identifier: Apache-2.0
"""Vendors the P0 WASI spike's inputs into apps/ipad/Resources/WASISpike (gitignored):
the WebAssembly/wasi-testsuite wasm32-wasip1 tests at a pinned commit, and
@bjorn3/browser_wasi_shim at a pinned tarball hash. Writes manifest.json for the runner."""
import hashlib, io, json, shutil, subprocess, tarfile, tempfile, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "apps/ipad/Resources/WASISpike"
SUITE_COMMIT = "e0aa527fab67f2f311882bcee4f62cc755433b73"   # branch prod/testsuite-base
SHIM_URL = "https://registry.npmjs.org/@bjorn3/browser_wasi_shim/-/browser_wasi_shim-0.4.2.tgz"
SHIM_SHA256 = "9c0281520d0e99f027ec7c1c79b4036c0f8168ed9bf98aba19db4737a1333782"
LANGS = ["c", "rust", "assemblyscript"]

# A hand-written module whose _start loops forever: proves the runner's timeout.
LOOP_WASM = bytes.fromhex(
    "0061736d" "01000000"                      # magic, version
    "01" "04" "01" "60" "00" "00"              # type section: one func type () -> ()
    "03" "02" "01" "00"                        # function section: func 0 has type 0
    "05" "03" "01" "00" "01"                   # memory section: one memory, min 1 page
    "07" "13" "02"                             # export section, 2 exports
    "06" "5f7374617274" "00" "00"              #   "_start" -> func 0
    "06" "6d656d6f7279" "02" "00"              #   "memory" -> memory 0
    "0a" "09" "01" "07" "00"                   # code section, 1 body of 7 bytes, no locals
    "0340" "0c00" "0b" "0b")                   #   loop { br 0 } end

def main():
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True)
    with tempfile.TemporaryDirectory() as tmp:
        suite = Path(tmp) / "suite"
        subprocess.run(["git", "clone", "-q", "--depth", "1", "--branch", "prod/testsuite-base",
                        "https://github.com/WebAssembly/wasi-testsuite.git", str(suite)], check=True)
        head = subprocess.run(["git", "-C", str(suite), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        if head != SUITE_COMMIT:
            raise SystemExit(f"wasi-testsuite moved: {head} != {SUITE_COMMIT}")
        shutil.copy(suite / "LICENSE", OUT / "LICENSE-wasi-testsuite")
        tests = []
        for lang in LANGS:
            src = suite / "tests" / lang / "testsuite" / "wasm32-wasip1"
            dst = OUT / "tests" / lang
            shutil.copytree(src, dst)
            for wasm in sorted(dst.glob("*.wasm")):
                cfg_path = wasm.with_suffix(".json")
                cfg = json.loads(cfg_path.read_text()) if cfg_path.exists() else {}
                files = []
                if "root" in cfg:
                    base = dst / cfg["root"]
                    for p in sorted(base.rglob("*")):
                        files.append({"path": str(p.relative_to(base)), "dir": p.is_dir()})
                tests.append({"lang": lang, "name": wasm.stem, "wasm": f"tests/{lang}/{wasm.name}",
                              "config": cfg, "rootBase": f"tests/{lang}/{cfg['root']}" if "root" in cfg else None,
                              "files": files})
    (OUT / "loop.wasm").write_bytes(LOOP_WASM)
    tests.append({"lang": "omnie", "name": "timeout-infinite-loop", "wasm": "loop.wasm",
                  "config": {}, "rootBase": None, "files": [], "expectTimeout": True})

    data = urllib.request.urlopen(SHIM_URL).read()
    if hashlib.sha256(data).hexdigest() != SHIM_SHA256:
        raise SystemExit("browser_wasi_shim checksum mismatch")
    with tarfile.open(fileobj=io.BytesIO(data)) as tar:
        for m in tar.getmembers():
            name = m.name
            if name.startswith("package/dist/") and name.endswith(".js") or name in ("package/LICENSE-MIT", "package/LICENSE-APACHE"):
                target = OUT / "shim" / Path(name).name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(tar.extractfile(m).read())
    (OUT / "manifest.json").write_text(json.dumps({"suiteCommit": SUITE_COMMIT, "tests": tests}, indent=1))
    print(f"vendored {len(tests)} tests into {OUT}")

if __name__ == "__main__":
    main()

#!/bin/sh
# SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
# SPDX-License-Identifier: Apache-2.0
# Builds RunKit's bundled JavaScript from the pinned lockfile in scripts/runkit:
#   - Sucrase (MIT): TypeScript → JavaScript, bundled into JS/sucrase.js
#   - Pyodide (MPL-2.0; CPython is PSF-2.0): Python in WebAssembly, copied into JS/pyodide/, with
#     its builds of jedi and parso (MIT) for Python code intelligence
#   - three.js (MIT): the first entry of the offline package cache, copied into JS/packages/three/
#   - marked and Mermaid (MIT): the Markdown preview, copied into JS/packages/
#   - TypeScript 5.9 (Apache-2.0): type checking, copied into JS/packages/typescript/
#   - Prettier (MIT): Format Document, copied into JS/packages/prettier/
#   - Ruff (MIT): Format Document for Python, its WebAssembly build, copied into JS/packages/ruff/
#   - WASI tools (tools/wasi/*, pinned by their Cargo.lock): built for wasm32-wasip1 into
#     JS/packages/wasi/, with every linked crate's licence. Needs `rustup target add wasm32-wasip1`.
# Output is gitignored.
set -eu
cd "$(dirname "$0")/runkit"
npm ci --no-audit --no-fund --ignore-scripts >/dev/null
JS=../../packages/RunKit/Sources/RunKit/JS
bun build entry.mjs --format iife --minify --outfile "$JS/sucrase.js" >/dev/null
cp node_modules/sucrase/LICENSE "$JS/sucrase-LICENSE.txt"

mkdir -p "$JS/pyodide"
for f in pyodide.mjs pyodide.asm.mjs pyodide.asm.wasm python_stdlib.zip pyodide-lock.json; do
  cp "node_modules/pyodide/$f" "$JS/pyodide/$f"
done
# Jedi and parso (MIT; pure Python): Python code intelligence, offline. Pyodide's own builds,
# from its CDN, checked against the sha256 in its lock file.
PYODIDE_VERSION=$(node -p 'require("./node_modules/pyodide/package.json").version')
for pkg in jedi parso; do
  file=$(node -p "require('./node_modules/pyodide/pyodide-lock.json').packages['$pkg'].file_name")
  sum=$(node -p "require('./node_modules/pyodide/pyodide-lock.json').packages['$pkg'].sha256")
  curl -fsSL "https://cdn.jsdelivr.net/pyodide/v$PYODIDE_VERSION/full/$file" -o "$JS/pyodide/$file"
  echo "$sum  $JS/pyodide/$file" | shasum -a 256 -c - >/dev/null
done
# License texts (the npm package ships none), from a pinned SPDX commit, checked.
SPDX=31ba1a50e5397e00a304dbadc76531740e89ee48
fetch_license() {
  curl -fsSL "https://raw.githubusercontent.com/spdx/license-list-data/$SPDX/text/$1.txt" -o "$JS/pyodide/$1.txt"
  echo "$2  $JS/pyodide/$1.txt" | shasum -a 256 -c - >/dev/null
}
fetch_license MPL-2.0 66a3107d5ad6a058aab753eaac2047ccb2ed0e39465dd0fe5844da3e300d5172
fetch_license PSF-2.0 ab745c5061d1dea43a3885e5b4b6befc7e983954954775c5736debeefcdfd89b

# The offline package cache's first entries (import-mapped by RunKit): three.js, MIT.
rm -rf "$JS/packages/three" && mkdir -p "$JS/packages/three/build" "$JS/packages/three/examples"
for f in three.module.js three.core.js three.webgpu.js three.webgpu.nodes.js three.tsl.js; do
  cp "node_modules/three/build/$f" "$JS/packages/three/build/$f"
done
cp -R node_modules/three/examples/jsm "$JS/packages/three/examples/jsm"
cp node_modules/three/LICENSE "$JS/packages/three/LICENSE"
# Type checking: the TypeScript 5 compiler (Apache-2.0; 7.x is the native Go port) and its lib files.
rm -rf "$JS/packages/typescript" && mkdir -p "$JS/packages/typescript/lib"
cp node_modules/typescript/lib/typescript.js "$JS/packages/typescript/typescript.js"
cp node_modules/typescript/lib/lib.d.ts node_modules/typescript/lib/lib.*.d.ts "$JS/packages/typescript/lib/"
cp node_modules/typescript/LICENSE.txt node_modules/typescript/ThirdPartyNoticeText.txt "$JS/packages/typescript/"
(cd "$JS/packages/typescript/lib" && ls lib.d.ts lib.*.d.ts) > "$JS/packages/typescript/libs.txt"

# Format Document: Prettier (MIT), its standalone build and the parsers for the languages the editor knows.
rm -rf "$JS/packages/prettier" && mkdir -p "$JS/packages/prettier/plugins"
cp node_modules/prettier/standalone.mjs node_modules/prettier/LICENSE node_modules/prettier/THIRD-PARTY-NOTICES.md "$JS/packages/prettier/"
for p in babel estree typescript postcss html markdown yaml; do cp "node_modules/prettier/plugins/$p.mjs" "$JS/packages/prettier/plugins/"; done

# Format Document for Python: Ruff's formatter (MIT), its WebAssembly build.
rm -rf "$JS/packages/ruff" && mkdir -p "$JS/packages/ruff"
cp node_modules/@astral-sh/ruff-wasm-web/ruff_wasm.js node_modules/@astral-sh/ruff-wasm-web/ruff_wasm_bg.wasm node_modules/@astral-sh/ruff-wasm-web/LICENSE "$JS/packages/ruff/"

# Markdown preview: marked (MIT) and Mermaid (MIT).
rm -rf "$JS/packages/marked" "$JS/packages/mermaid" && mkdir -p "$JS/packages/marked" "$JS/packages/mermaid"
cp node_modules/marked/lib/marked.esm.js "$JS/packages/marked/marked.esm.js"
cp node_modules/marked/LICENSE "$JS/packages/marked/LICENSE"
cp node_modules/mermaid/dist/mermaid.min.js "$JS/packages/mermaid/mermaid.min.js"
cp node_modules/mermaid/LICENSE "$JS/packages/mermaid/LICENSE"

# WASI tools RunKit carries: built from source with the committed lockfiles.
rm -rf "$JS/packages/wasi" && mkdir -p "$JS/packages/wasi"
for tool in ../../tools/wasi/*/; do
  name=$(basename "$tool")
  (cd "$tool" && cargo build --release --locked --target wasm32-wasip1 --quiet)
  bin=$(cd "$tool" && cargo metadata --format-version 1 --no-deps | python3 -c 'import json,sys; print([t["name"] for p in json.load(sys.stdin)["packages"] for t in p["targets"] if "bin" in t["kind"]][0])')
  cp "$tool/target/wasm32-wasip1/release/$bin.wasm" "$JS/packages/wasi/$bin.wasm"
  python3 ../collect-cargo-licenses.py "$tool" "$JS/packages/wasi/$bin-LICENSES.txt" >/dev/null
done

echo "built sucrase $(node -p 'require("./node_modules/sucrase/package.json").version'), three $(node -p 'require("./node_modules/three/package.json").version') ($(du -sh "$JS/packages/three" | cut -f1)), pyodide $(node -p 'require("./node_modules/pyodide/package.json").version') ($(du -sh "$JS/pyodide" | cut -f1)), WASI tools: $(ls "$JS/packages/wasi" | grep -c '\.wasm$'), bun $(bun --version)"

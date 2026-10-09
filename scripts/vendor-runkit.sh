#!/bin/sh
# SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
# SPDX-License-Identifier: Apache-2.0
# Builds RunKit's bundled JavaScript from the pinned lockfile in scripts/runkit:
#   - Sucrase (MIT): TypeScript → JavaScript, bundled into JS/sucrase.js
#   - Pyodide (MPL-2.0; CPython is PSF-2.0): Python in WebAssembly, copied into JS/pyodide/
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
# License texts (the npm package ships none), from a pinned SPDX commit, checked.
SPDX=31ba1a50e5397e00a304dbadc76531740e89ee48
fetch_license() {
  curl -fsSL "https://raw.githubusercontent.com/spdx/license-list-data/$SPDX/text/$1.txt" -o "$JS/pyodide/$1.txt"
  echo "$2  $JS/pyodide/$1.txt" | shasum -a 256 -c - >/dev/null
}
fetch_license MPL-2.0 66a3107d5ad6a058aab753eaac2047ccb2ed0e39465dd0fe5844da3e300d5172
fetch_license PSF-2.0 ab745c5061d1dea43a3885e5b4b6befc7e983954954775c5736debeefcdfd89b

echo "built sucrase $(node -p 'require("./node_modules/sucrase/package.json").version'), pyodide $(node -p 'require("./node_modules/pyodide/package.json").version') ($(du -sh "$JS/pyodide" | cut -f1)), bun $(bun --version)"

#!/bin/sh
# SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
# SPDX-License-Identifier: Apache-2.0
# Builds RunKit's bundled TypeScript transpiler (Sucrase, MIT) from the pinned lockfile in
# scripts/runkit. Output is gitignored: packages/RunKit/Sources/RunKit/JS/sucrase.js
set -eu
cd "$(dirname "$0")/runkit"
npm ci --no-audit --no-fund --ignore-scripts >/dev/null
OUT=../../packages/RunKit/Sources/RunKit/JS/sucrase.js
bun build entry.mjs --format iife --minify --outfile "$OUT" >/dev/null
cp node_modules/sucrase/LICENSE ../../packages/RunKit/Sources/RunKit/JS/sucrase-LICENSE.txt
echo "built $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes, sucrase $(node -p 'require("./node_modules/sucrase/package.json").version'), bun $(bun --version))"

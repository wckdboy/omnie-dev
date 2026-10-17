#!/bin/sh
# SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
# SPDX-License-Identifier: Apache-2.0
# Removes what builds generate: the monorepo's derived data, each package's .build, and Xcode's
# DerivedData for this project. A long-lived checkout grew enough derived data to abort an archive;
# this is the one command that puts the disk back. Sources, vendored inputs (packages/GitKit/Vendor,
# LangKit's grammars, RunKit's JS) and Package.resolved are never touched.
set -eu
cd "$(dirname "$0")/.."

echo "Removing .build/ (archives, derived data, SwiftPM caches)…"
rm -rf .build

for dir in packages/*/; do
  if [ -d "${dir}.build" ]; then
    echo "Removing ${dir}.build…"
    rm -rf "${dir}.build"
  fi
done

# Xcode's DerivedData for this project (its folder name is "OmnieDev-<hash>").
for dir in "$HOME"/Library/Developer/Xcode/DerivedData/OmnieDev-*; do
  [ -d "$dir" ] || continue
  echo "Removing $(basename "$dir")…"
  rm -rf "$dir"
done

echo "Clean. Sources and vendored inputs are untouched."

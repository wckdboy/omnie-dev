#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
# SPDX-License-Identifier: Apache-2.0
# Runs every test suite: each package (EditorKit on an iPad simulator, it's iOS-only), then the
# app's UI tests with --ui. Needs the vendored inputs (scripts/build-git-deps.sh,
# scripts/vendor-runkit.sh). Prints one line per suite and exits non-zero if any failed.
#   scripts/test-all.sh [--ui] [simulator id]
# XCODEBUILD_FLAGS adds flags to the xcodebuild runs (CI: CODE_SIGNING_ALLOWED=NO).
set -uo pipefail
EXTRA=(${XCODEBUILD_FLAGS:-})

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UI=0
SIM=""
for arg in "$@"; do
  case "$arg" in
    --ui) UI=1 ;;
    *) SIM="$arg" ;;
  esac
done
if [ -z "$SIM" ]; then
  SIM=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = [d for runtime, ds in json.load(sys.stdin)["devices"].items() if "iOS" in runtime for d in ds]
ipads = [d for d in devices if "iPad" in d["name"]]
print((ipads or devices)[0]["udid"] if (ipads or devices) else "")')
fi

failed=0
report() { # name status detail
  printf "%-14s %s %s\n" "$1" "$2" "$3"
  [ "$2" = "ok" ] || failed=1
}

for dir in "$ROOT"/packages/*/; do
  name=$(basename "$dir")
  if [ "$name" = "EditorKit" ]; then
    out=$(cd "$dir" && xcodebuild test -scheme EditorKit -destination "id=$SIM" -derivedDataPath "$ROOT/.build/test-all/EditorKit" ${EXTRA[@]+"${EXTRA[@]}"} 2>&1)
  else
    out=$(cd "$dir" && swift test 2>&1)
  fi
  summary=$(echo "$out" | grep -aE "Test run with [0-9]+ tests" | tail -1 | sed 's/^[^T]*//')
  if echo "$out" | grep -aqE "✘ Test run|TEST FAILED|error: "; then
    report "$name" FAILED "$summary"
    echo "$out" | grep -aE "✘|error:" | head -8 | sed 's/^/    /'
  else
    report "$name" ok "$summary"
  fi
done

if [ "$UI" = 1 ]; then
  out=$(cd "$ROOT" && xcodebuild test -project OmnieDev.xcodeproj -scheme OmnieDev -destination "id=$SIM" \
        -derivedDataPath "$ROOT/.build/test-all/app" -only-testing:OmnieDevUITests ${EXTRA[@]+"${EXTRA[@]}"} 2>&1)
  summary=$(echo "$out" | grep -aE "Executed [0-9]+ tests" | tail -1 | sed 's/^[[:space:]]*//')
  if echo "$out" | grep -aq "TEST SUCCEEDED"; then report "UI tests" ok "$summary"; else
    report "UI tests" FAILED "$summary"
    echo "$out" | grep -aE "error:|\[a11y\] [^(]" | head -8 | sed 's/^/    /'
  fi
fi

exit $failed

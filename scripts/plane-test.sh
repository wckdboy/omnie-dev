#!/bin/sh
# SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
# SPDX-License-Identifier: Apache-2.0
# The P3 plane test (PLAN.md §22) on a connected iPad with a debug build installed:
#   scripts/plane-test.sh <device id>
# Makes fixtures/plane-demo a bare git repo, copies it into the app's Documents under a new name,
# and runs -OmniePlaneTest: clone and prepare online; in plane mode the local agent fixes the
# fixture, then tests, type check, preview, Stage, commit and a queued push; plane mode off, the
# push lands. Approval prompts are answered by -OmnieTestApprove (debug builds only).
set -eu
DEVICE=${1:?usage: scripts/plane-test.sh <device id>}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
NAME="plane-remote-$(date +%s).git"
cp -R "$ROOT/fixtures/plane-demo" "$WORK/src"
git -C "$WORK/src" init -q -b main
git -C "$WORK/src" add -A
git -C "$WORK/src" -c user.name=Fixture -c user.email=fixture@omnie.invalid commit -q -m "Planet and moon"
git clone -q --bare "$WORK/src" "$WORK/$NAME"
xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer --domain-identifier ai.wckd.omniedev \
  --source "$WORK/$NAME" --destination "Documents/$NAME" >/dev/null
LOG="$WORK/console.txt"
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing --console ai.wckd.omniedev -- \
  -OmniePlaneTest "$NAME" -OmnieTestApprove > "$LOG" 2>&1 &
for _ in $(seq 1 200); do
  grep -a -q "\[plane\] PASS\|\[plane\] FAIL\|\[plane\] ✗ no Documents" "$LOG" && break
  sleep 3
done
grep -a "\[plane\]" "$LOG"
grep -a -q "\[plane\] PASS" "$LOG"

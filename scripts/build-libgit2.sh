#!/usr/bin/env bash
# Builds libgit2 as a static XCFramework (iOS device, iOS simulator, macOS) for GitKit.
# Output: Packages/OmnieKit/Vendor/Clibgit2.xcframework (gitignored; re-run this script to recreate it).
#
# HTTPS uses Apple's SecureTransport. SSH is off for now: libssh2 with the
# Secure Enclave signing callback is a separate step (PLAN.md §9.2, P0 spike 5).
set -euo pipefail

LIBGIT2_TAG="v1.9.7"
LIBGIT2_COMMIT="49e408b3208bc3093757a1c2db938d3590f3f412"
DEPLOYMENT_TARGET="26.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.build/vendor"
SRC="$WORK/libgit2"
OUT="$ROOT/Packages/OmnieKit/Vendor/Clibgit2.xcframework"

mkdir -p "$WORK"
if [ ! -d "$SRC" ]; then
  git clone --quiet --depth 1 --branch "$LIBGIT2_TAG" https://github.com/libgit2/libgit2.git "$SRC"
fi
actual="$(git -C "$SRC" rev-parse HEAD)"
if [ "$actual" != "$LIBGIT2_COMMIT" ]; then
  echo "libgit2 checkout is $actual, expected $LIBGIT2_COMMIT for $LIBGIT2_TAG" >&2
  exit 1
fi

build_slice() {
  local name="$1" system="$2" sysroot="$3"
  local build="$WORK/build-$name" prefix="$WORK/install-$name"
  rm -rf "$build" "$prefix"
  cmake -S "$SRC" -B "$build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME="$system" \
    -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTS=OFF \
    -DBUILD_CLI=OFF \
    -DUSE_SSH=OFF \
    -DUSE_HTTPS=SecureTransport \
    -DUSE_SHA1=CollisionDetection \
    -DUSE_BUNDLED_ZLIB=ON \
    -DUSE_NTLMCLIENT=OFF \
    -DUSE_GSSAPI=OFF \
    -DUSE_ICONV=ON \
    -DREGEX_BACKEND=builtin \
    -DUSE_HTTP_PARSER=builtin \
    > "$WORK/cmake-$name.log"
  cmake --build "$build" --target install > "$WORK/build-$name.log"

  # Swift imports the C API through this module.
  cat > "$prefix/include/module.modulemap" <<'EOF'
module Clibgit2 {
    header "git2.h"
    export *
    link "iconv"
    link framework "CoreFoundation"
    link framework "Security"
}
EOF
  echo "Built $name"
}

build_slice ios-device iOS iphoneos
build_slice ios-simulator iOS iphonesimulator
build_slice macos Darwin macosx

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
args=()
for slice in ios-device ios-simulator macos; do
  args+=(-library "$WORK/install-$slice/lib/libgit2.a" -headers "$WORK/install-$slice/include")
done
xcodebuild -create-xcframework "${args[@]}" -output "$OUT" > /dev/null
echo "Wrote $OUT"

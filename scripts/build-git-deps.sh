#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
# SPDX-License-Identifier: Apache-2.0
# Builds GitKit's native dependencies as one static XCFramework (iOS device, iOS simulator, macOS):
#   OpenSSL (libcrypto only) -> libssh2 -> libgit2 (SSH via libssh2, HTTPS via SecureTransport)
# The three static libraries are merged into a single libgit2 archive.
# Output: packages/GitKit/Vendor/Clibgit2.xcframework (gitignored; re-run this script to recreate it).
set -euo pipefail

OPENSSL_VERSION="3.6.5"
OPENSSL_SHA256="a2157c2830efdec3788939b00c9b0638306d3f0bbb76dc4832ee503bb397df98"
LIBSSH2_VERSION="1.11.1"
LIBSSH2_SHA256="d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7"
LIBGIT2_TAG="v1.9.7"
LIBGIT2_COMMIT="49e408b3208bc3093757a1c2db938d3590f3f412"
DEPLOYMENT_TARGET="26.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.build/vendor"
OUT="$ROOT/packages/GitKit/Vendor/Clibgit2.xcframework"
JOBS="$(sysctl -n hw.ncpu)"
mkdir -p "$WORK"
cd "$WORK"

fetch() { # url file sha256
  local url="$1" file="$2" sha="$3"
  [ -f "$file" ] || curl -fsSL "$url" -o "$file"
  echo "$sha  $file" | shasum -a 256 -c --quiet - || { echo "Checksum mismatch for $file" >&2; exit 1; }
}

fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
  "openssl-$OPENSSL_VERSION.tar.gz" "$OPENSSL_SHA256"
fetch "https://libssh2.org/download/libssh2-$LIBSSH2_VERSION.tar.gz" "libssh2-$LIBSSH2_VERSION.tar.gz" "$LIBSSH2_SHA256"
[ -d "openssl-$OPENSSL_VERSION" ] || tar xzf "openssl-$OPENSSL_VERSION.tar.gz"
[ -d "libssh2-$LIBSSH2_VERSION" ] || tar xzf "libssh2-$LIBSSH2_VERSION.tar.gz"
if [ ! -d libgit2 ]; then
  git clone --quiet --depth 1 --branch "$LIBGIT2_TAG" https://github.com/libgit2/libgit2.git libgit2
fi
[ "$(git -C libgit2 rev-parse HEAD)" = "$LIBGIT2_COMMIT" ] || { echo "libgit2 is not at $LIBGIT2_COMMIT" >&2; exit 1; }

build_slice() { # name openssl-target min-version-flag cmake-system sysroot
  local name="$1" ossl_target="$2" min_flag="$3" system="$4" sysroot="$5"
  local dir="$WORK/$name" prefix="$WORK/$name/prefix"
  rm -rf "$dir"
  mkdir -p "$dir/openssl" "$prefix"
  local log="$dir/build.log"

  # OpenSSL: libcrypto only, static.
  (cd "$dir/openssl" && "$WORK/openssl-$OPENSSL_VERSION/Configure" "$ossl_target" \
      no-shared no-tests no-apps no-docs no-ui-console no-engine no-async no-module \
      "$min_flag" --prefix="$prefix" --libdir=lib >> "$log" 2>&1 \
    && make -j"$JOBS" build_libs >> "$log" 2>&1 \
    && make install_dev >> "$log" 2>&1)
  rm -f "$prefix"/lib/libssl.*

  local cmake_common=(
    -G Ninja
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_SYSTEM_NAME="$system"
    -DCMAKE_OSX_SYSROOT="$sysroot"
    -DCMAKE_OSX_ARCHITECTURES=arm64
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
    -DCMAKE_INSTALL_PREFIX="$prefix"
    -DCMAKE_PREFIX_PATH="$prefix"
    -DCMAKE_FIND_ROOT_PATH="$prefix"
    -DBUILD_SHARED_LIBS=OFF
  )

  # libssh2 on OpenSSL's libcrypto.
  cmake -S "$WORK/libssh2-$LIBSSH2_VERSION" -B "$dir/libssh2" "${cmake_common[@]}" \
    -DCRYPTO_BACKEND=OpenSSL \
    -DOPENSSL_ROOT_DIR="$prefix" \
    -DOPENSSL_USE_STATIC_LIBS=TRUE \
    -DBUILD_STATIC_LIBS=ON \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_TESTING=OFF \
    -DENABLE_ZLIB_COMPRESSION=OFF >> "$log" 2>&1
  cmake --build "$dir/libssh2" --target install >> "$log" 2>&1

  # libgit2. pkg-config is pinned to our prefix so a Homebrew libssh2 can never be picked up.
  # The in-memory-key check can't link a test program when cross-compiling, so it's set directly.
  PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" PKG_CONFIG_PATH="" \
  cmake -S "$WORK/libgit2" -B "$dir/libgit2" "${cmake_common[@]}" \
    -DBUILD_TESTS=OFF \
    -DBUILD_CLI=OFF \
    -DUSE_SSH=libssh2 \
    -DHAVE_LIBSSH2_MEMORY_CREDENTIALS=1 \
    -DUSE_HTTPS=SecureTransport \
    -DUSE_SHA1=CollisionDetection \
    -DUSE_BUNDLED_ZLIB=ON \
    -DUSE_NTLMCLIENT=OFF \
    -DUSE_GSSAPI=OFF \
    -DUSE_ICONV=ON \
    -DREGEX_BACKEND=builtin \
    -DUSE_HTTP_PARSER=builtin >> "$log" 2>&1
  grep -q "SSH, using libssh2" "$log" || { echo "libgit2 did not enable libssh2 for $name; see $log" >&2; exit 1; }
  cmake --build "$dir/libgit2" --target install >> "$log" 2>&1

  # One archive, and only libgit2's public headers.
  libtool -static -o "$dir/libgit2.a" "$prefix/lib/libgit2.a" "$prefix/lib/libssh2.a" "$prefix/lib/libcrypto.a" 2>> "$log"
  mkdir -p "$dir/headers"
  cp -R "$prefix/include/git2.h" "$prefix/include/git2" "$dir/headers/"
  cat > "$dir/headers/module.modulemap" <<'EOF'
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

build_slice ios-device ios64-xcrun "-mios-version-min=$DEPLOYMENT_TARGET" iOS iphoneos
build_slice ios-simulator iossimulator-arm64-xcrun "-mios-simulator-version-min=$DEPLOYMENT_TARGET" iOS iphonesimulator
build_slice macos darwin64-arm64-cc "-mmacosx-version-min=$DEPLOYMENT_TARGET" Darwin macosx

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
args=()
for slice in ios-device ios-simulator macos; do
  args+=(-library "$WORK/$slice/libgit2.a" -headers "$WORK/$slice/headers")
done
xcodebuild -create-xcframework "${args[@]}" -output "$OUT" > /dev/null
echo "Wrote $OUT"

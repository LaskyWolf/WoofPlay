#!/bin/bash
# Builds TorrentNative.xcframework (libtorrent + bridge.cpp) for iPhone, from pinned source only.
set -euo pipefail
cd "$(dirname "$0")"

# libtorrent v2.0.15, pinned by commit so a moved tag can't change what gets built.
LIBTORRENT_COMMIT=1eb18faeae156d8dbbab42935c082f8b81f50989
DEPLOYMENT_TARGET=26.0

work=build
rm -rf "$work" TorrentNative.xcframework
mkdir -p "$work/libtorrent"
git -C "$work/libtorrent" init -q
git -C "$work/libtorrent" fetch -q --depth 1 https://github.com/arvidn/libtorrent.git "$LIBTORRENT_COMMIT"
git -C "$work/libtorrent" checkout -q FETCH_HEAD
# try_signal is the only submodule a build needs; its commit is pinned by libtorrent itself.
git -C "$work/libtorrent" submodule update -q --init --depth 1 deps/try_signal

boost="$(brew --prefix boost)"

# No OpenSSL: encryption with peers (MSE) is built into libtorrent. Only HTTPS trackers need it.
cmake -S . -B "$work/ios" -G Ninja \
    -DLIBTORRENT_SOURCE_DIR="$PWD/$work/libtorrent" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DCMAKE_CXX_FLAGS="-DNDEBUG -DTORRENT_HAVE_MMAP=0" \
    -DCMAKE_DISABLE_FIND_PACKAGE_OpenSSL=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_GnuTLS=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_LibGcrypt=ON \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
    -DBOOST_ROOT="$boost" \
    -DBoost_INCLUDE_DIR="$boost/include" \
    -Ddeprecated-functions=OFF \
    -Dbuild_tests=OFF -Dbuild_examples=OFF -Dbuild_tools=OFF -Dpython-bindings=OFF
cmake --build "$work/ios"

# One static library holding both, so the app links a single file.
libtool -static -o "$work/libTorrentNative.a" \
    "$work/ios/libTorrentNative.a" \
    "$(find "$work/ios/libtorrent" -name 'libtorrent-rasterbar.a' | head -1)"
xcodebuild -create-xcframework \
    -library "$work/libTorrentNative.a" -headers include \
    -output TorrentNative.xcframework
echo "Built $(pwd)/TorrentNative.xcframework"

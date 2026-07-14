#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
    echo "usage: build_gamenetworking_sockets.sh SOURCE OUTPUT DEBUG_OR_RELEASE" >&2
    exit 64
fi

source_dir=$1
output_dir=$2
build_type=$3
homebrew_prefix=${HOMEBREW_PREFIX:-/opt/homebrew}

cmake_bin=${CMAKE:-"$homebrew_prefix/bin/cmake"}
if [ ! -x "$cmake_bin" ]; then
    echo "GameNetworkingSockets requires CMake; run: brew install cmake ninja protobuf openssl@3" >&2
    exit 69
fi

prefix_path="$homebrew_prefix/opt/openssl@3;$homebrew_prefix/opt/protobuf;$homebrew_prefix/opt/abseil"

"$cmake_bin" \
    -S "$source_dir" \
    -B "$output_dir" \
    -G Ninja \
    -DBUILD_SHARED_LIB=OFF \
    -DBUILD_STATIC_LIB=ON \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_TESTS=OFF \
    -DBUILD_TOOLS=OFF \
    -DENABLE_ICE=OFF \
    -DUSE_STEAMWEBRTC=OFF \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_BUILD_TYPE="$build_type" \
    -DCMAKE_PREFIX_PATH="$prefix_path"

"$cmake_bin" --build "$output_dir" --target GameNetworkingSockets_s --parallel

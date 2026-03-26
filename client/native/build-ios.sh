#!/bin/bash
# Build the SMPL native audio library for Claire
# Outputs: build/libclaire_native.a (and all dependency .a files)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"

echo "=== Building Claire native audio library ==="

# Initialize atria submodules if needed
ATRIA_DIR="$SCRIPT_DIR/../../submodules/atria"
if [ ! -f "$ATRIA_DIR/composeApp/native/CMakeLists.txt" ]; then
    echo "Error: Atria submodule not initialized. Run:"
    echo "  cd $(dirname $SCRIPT_DIR)/.. && git submodule update --init --recursive"
    exit 1
fi

# Initialize atria's own submodules
pushd "$ATRIA_DIR" > /dev/null
git submodule update --init --recursive 2>/dev/null || true
popd > /dev/null

# Build for macOS (arm64)
echo "=== Building for macOS arm64 ==="
mkdir -p "$BUILD_DIR/macos-arm64"
cmake -S "$SCRIPT_DIR" -B "$BUILD_DIR/macos-arm64" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_SYSTEM_NAME=Darwin

cmake --build "$BUILD_DIR/macos-arm64" --config Release -j $(sysctl -n hw.ncpu)

echo ""
echo "=== Build complete ==="
echo "Libraries in: $BUILD_DIR/macos-arm64/"
ls -lh "$BUILD_DIR/macos-arm64/"*.a 2>/dev/null || echo "(check subdirs)"

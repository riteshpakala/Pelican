#!/bin/bash
# Compiles Frigate's vendored MLX Metal shaders into mlx.metallib next to the
# Pelican binary. MLX loads this at runtime for GPU execution; without it the
# app fails with "Failed to load the default metallib".
#
# Run once after `swift build` (or `swift build -c release`):
#   ./build-metallib.sh [debug|release]   (default: debug)
#
# Override Frigate's location with FRIGATE_DIR=/path/to/Frigate.

set -e

CONFIG="${1:-debug}"
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
FRIGATE_DIR="${FRIGATE_DIR:-/Users/ritesh/Documents/rao/repositories/Frigate}"
MLX_METAL_DIR="$FRIGATE_DIR/Sources/Cmlx/mlx-generated/metal"
BINARY_DIR="$REPO_ROOT/.build/$CONFIG"
TMP_DIR="$(mktemp -d)"
METALLIB_OUT="$BINARY_DIR/mlx.metallib"

if [ ! -d "$MLX_METAL_DIR" ]; then
    echo "Error: MLX metal shaders not found at $MLX_METAL_DIR"
    echo "Set FRIGATE_DIR or run 'swift build' first to resolve dependencies."
    exit 1
fi

echo "Compiling MLX Metal shaders from $MLX_METAL_DIR ..."

AIR_FILES=()
while IFS= read -r -d '' metal_file; do
    base="$(basename "$metal_file" .metal)"
    air_file="$TMP_DIR/$base.air"
    xcrun -sdk macosx metal \
        -x metal \
        -fno-fast-math \
        -Wno-c++17-extensions \
        -Wno-c++20-extensions \
        -mmacosx-version-min=14.0 \
        -I "$MLX_METAL_DIR" \
        -c "$metal_file" \
        -o "$air_file"
    AIR_FILES+=("$air_file")
done < <(find "$MLX_METAL_DIR" -name "*.metal" -print0)

echo "Linking mlx.metallib ..."
xcrun -sdk macosx metallib "${AIR_FILES[@]}" -o "$METALLIB_OUT"

rm -rf "$TMP_DIR"
echo "Done: $METALLIB_OUT"

# Xcode builds to DerivedData/Pelican-*/Build/Products/<Config>/, which has no
# mlx.metallib next to the binary — copy it there too so the Xcode scheme works.
# (Xcode wipes this dir on Clean Build Folder; re-run this script afterwards.)
XCODE_CONFIG="$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}"  # debug → Debug
for products in "$HOME"/Library/Developer/Xcode/DerivedData/Pelican-*/Build/Products/"$XCODE_CONFIG"; do
    if [ -d "$products" ]; then
        cp "$METALLIB_OUT" "$products/mlx.metallib"
        echo "Copied to $products/mlx.metallib"
    fi
done

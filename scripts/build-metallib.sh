#!/usr/bin/env bash
# WHAT: Install MLX's mlx.metallib next to Pelican's binaries in .build, and optionally inside an
#       assembled app bundle.
# PIN:  A DELEGATE, NOT AN IMPLEMENTATION. Frigate owns the .metal sources and the compile; this
#       script finds Frigate's canonical scripts/build-metallib.sh and points it at this package.
#       `swift build` has NO Metal step, so without this the first GPU op aborts with
#       "Failed to load the default metallib". MLX probes `mlx.metallib` beside the RUNNING binary
#       first — that is also what ModelStore.metallibPresent checks.
#       CODESIGN TREATS ANY FILE UNDER Contents/MacOS AS NESTED CODE, so every installed metallib
#       is ad-hoc signed here; make-app.sh re-signs the app's copy with the release identity.
#       Xcode builds to DerivedData/Pelican-*/Build/Products/<Config>/, which has no metallib;
#       the build's copy is placed there too (re-run after Clean Build Folder).
#
#   ./scripts/build-metallib.sh [debug|release] [--app build/Pelican.app]
#   FRIGATE_DIR=/path/to/Frigate ./scripts/build-metallib.sh release
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRIGATE_DIR="${FRIGATE_DIR:-$REPO_ROOT/../../rao/repositories/Frigate}"
CANONICAL="$FRIGATE_DIR/scripts/build-metallib.sh"

if [ ! -x "$CANONICAL" ]; then
    echo "build-metallib: cannot find $CANONICAL" >&2
    echo "  Set FRIGATE_DIR to the Frigate checkout Package.swift builds against." >&2
    exit 1
fi

CONFIG="debug"
APP=""
while [ $# -gt 0 ]; do
    case "$1" in
        debug|release) CONFIG="$1"; shift ;;
        --app) APP="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "build-metallib: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

if [ -n "$APP" ]; then
    "$CANONICAL" "$CONFIG" --package "$REPO_ROOT" --app "$APP"
else
    "$CANONICAL" "$CONFIG" --package "$REPO_ROOT"
fi

sign_metallibs() {  # dir → ad-hoc sign every metallib under it (xattrs stripped first)
    find "$1" \( -name mlx.metallib -o -name default.metallib \) -type f | while read -r lib; do
        xattr -c "$lib" 2>/dev/null || true
        codesign --force --sign - "$lib" 2>/dev/null || true
    done
}

BUILD_DIR="$(cd "$REPO_ROOT/.build/$CONFIG" 2>/dev/null && pwd -P || true)"
if [ -n "$BUILD_DIR" ]; then
    sign_metallibs "$BUILD_DIR"
    find "$BUILD_DIR" -maxdepth 1 -name '*.xctest' -type d | while read -r bundle; do
        codesign --force --sign - "$bundle" 2>/dev/null \
            || echo "build-metallib: could not re-seal $(basename "$bundle")" >&2
    done

    XCODE_CONFIG="$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}"   # debug → Debug
    for products in "$HOME"/Library/Developer/Xcode/DerivedData/Pelican-*/Build/Products/"$XCODE_CONFIG"; do
        if [ -d "$products" ] && [ -f "$BUILD_DIR/mlx.metallib" ]; then
            cp -f "$BUILD_DIR/mlx.metallib" "$products/mlx.metallib"
            echo "build-metallib: copied into $products"
        fi
    done
fi
if [ -n "$APP" ]; then
    sign_metallibs "$APP/Contents/MacOS"
fi
echo "build-metallib: done"

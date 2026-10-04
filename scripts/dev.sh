#!/bin/bash
# WHAT: Build + install the metallib + run.
# PIN:  Not `swift run`. MLX loads mlx.metallib from beside the running binary and
#       `swift build` has no Metal step, so the metallib has to land in .build/$CONFIG
#       between the build and the launch. build-metallib.sh only recompiles when a shader
#       changed, so running it every time is close to free.
# PIN:  --build-system native, same as make-app.sh (PELICAN_BUILD_SYSTEM=swiftbuild flips it).
# OUT:  build-metallib.sh, then exec .build/$CONFIG/Pelican with any arguments passed through.
#
#   ./scripts/dev.sh
#   CONFIG=release ./scripts/dev.sh
#   ./scripts/dev.sh --trust-probe 20
#   PELICAN_LEDGER_DIR=/tmp/ledger ./scripts/dev.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-debug}"
BUILD_SYSTEM="${PELICAN_BUILD_SYSTEM:-native}"
cd "$REPO_ROOT"

echo "▸ swift build ($CONFIG, $BUILD_SYSTEM)"
swift build --build-system "$BUILD_SYSTEM" -c "$CONFIG" --product Pelican

"$REPO_ROOT/scripts/build-metallib.sh" "$CONFIG"

exec "$REPO_ROOT/.build/$CONFIG/Pelican" "$@"

#!/bin/bash
# WHAT: Assemble build/Pelican.app from a release build.
# OUT:  build/Pelican.app — binary, Info.plist (stamped with PelicanBuildCommit and
#       PelicanBuildDate), SwiftPM resource bundles in Contents/Resources, mlx.metallib beside
#       the executable, the app icon (macOS 26 layered Assets.car + AppIcon.icns fallback).
#       build/app-metadata.json — version, build, commit, date, signer and the SHA-256 of the
#       signed executable, so a running copy can be checked against the build.
# IN:   Nothing, for a contributor: signs ad-hoc when no identity is found.
#         SIGN_IDENTITY="…"   a codesigning identity (name or SHA-1) to use
#         DEVELOPER_ID=1      sign for distribution: hardened runtime + secure timestamp, and
#                             require a "Developer ID Application" identity (found in the
#                             keychain by that prefix unless SIGN_IDENTITY names one)
#         PELICAN_BUILD_SYSTEM=swiftbuild   see the PIN below
#         FRIGATE_DIR=…       the Frigate checkout (default: ../../rao/repositories/Frigate)
# PIN:  MLX finds its kernels as `mlx.metallib` NEXT TO THE RUNNING BINARY: Contents/MacOS holds
#       a symlink to the copy in Contents/Resources (see below), placed before signing.
# PIN:  BUILD SYSTEM. SwiftPM's default engine tries to compile Frigate's vendored .metal
#       sources and fails where the Metal toolchain stub is broken; `native` has no Metal step
#       (build-metallib.sh does it with xcrun). PELICAN_BUILD_SYSTEM=swiftbuild flips back.
# PIN:  Sign inside-out, never --deep. Package.swift and Support/Info.plist must agree on the
#       minimum macOS. Pelican's own signing team, certificate and profile are never written in
#       this repository.
#
#   ./scripts/make-app.sh [--install]
#   DEVELOPER_ID=1 ./scripts/make-app.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_ROOT/build/Pelican.app"
METADATA="$REPO_ROOT/build/app-metadata.json"
CONFIG=release
INSTALL=0
BUILD_SYSTEM="${PELICAN_BUILD_SYSTEM:-native}"
cd "$REPO_ROOT"

while [ $# -gt 0 ]; do
    case "$1" in
        --install) INSTALL=1; shift ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "make-app: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

fail() { echo "make-app: $*" >&2; exit 1; }

# The plist and the manifest must agree on the OS floor (.macOS(.v15) or .macOS("15.0")).
PKG_OS="$(sed -nE 's/.*\.macOS\(\.v([0-9]+)\).*/\1.0/p; s/.*\.macOS\("([0-9.]+)"\).*/\1/p' Package.swift | head -1)"
PLIST_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Support/Info.plist)"
[ "$PKG_OS" = "$PLIST_OS" ] || fail "Package.swift says macOS $PKG_OS but Support/Info.plist says $PLIST_OS"

echo "▸ swift build -c $CONFIG ($BUILD_SYSTEM)"
swift build --build-system "$BUILD_SYSTEM" -c $CONFIG --product Pelican

echo "▸ assembling $APP_DIR"
rm -rf "$APP_DIR" "$METADATA"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp ".build/$CONFIG/Pelican" "$APP_DIR/Contents/MacOS/Pelican"
cp Support/Info.plist "$APP_DIR/Contents/Info.plist"

commit="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
[ -z "$(git status --porcelain 2>/dev/null)" ] || commit="$commit-dirty"
built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
/usr/libexec/PlistBuddy -c "Add :PelicanBuildCommit string $commit" \
    -c "Add :PelicanBuildDate string $built_at" "$APP_DIR/Contents/Info.plist"
echo "▸ stamped PelicanBuildCommit $commit, PelicanBuildDate $built_at"

# SwiftPM resource bundles (Frigate's Hub tokenizer fallbacks, which it looks up under
# Bundle.main.resourceURL; swift-crypto's privacy manifest). Enumerated, not named: the set
# grows whenever a dependency ships resources.
copied=0
for bundle in ".build/$CONFIG/"*.bundle; do
    [ -d "$bundle" ] || continue
    cp -R "$bundle" "$APP_DIR/Contents/Resources/"
    copied=$((copied + 1))
done
echo "▸ copied $copied resource bundle(s)"

# The metallib lives in Contents/Resources, sealed like any resource, with a relative symlink
# beside the executable where MLX looks. As a file in Contents/MacOS it would be nested code
# whose signature rides in extended attributes, which copying and packaging can drop.
echo "▸ mlx.metallib → Contents/Resources, linked from Contents/MacOS"
"$REPO_ROOT/scripts/build-metallib.sh" "$CONFIG" --app "$APP_DIR"
[ -f "$APP_DIR/Contents/MacOS/mlx.metallib" ] || fail "no mlx.metallib in the app"
mv "$APP_DIR/Contents/MacOS/mlx.metallib" "$APP_DIR/Contents/Resources/mlx.metallib"
ln -s ../Resources/mlx.metallib "$APP_DIR/Contents/MacOS/mlx.metallib"

# Dock and Finder icon, before signing (Resources is sealed). macOS 26+ reads the layered icon
# (Assets.car, named by CFBundleIconName); older systems and anything reading
# CFBundleIconFile use AppIcon.icns. The layered .icon format needs a 26.0 target for actool;
# the app's own floor stays in Info.plist.
echo "▸ app icon"
ACTOOL_TARGET="$PLIST_OS"
[ "${PLIST_OS%%.*}" -ge 26 ] 2>/dev/null || ACTOOL_TARGET=26.0
ACTOOL_OUT="$(xcrun actool Support/AppIcon/AppIcon.icon --compile "$APP_DIR/Contents/Resources" \
    --platform macosx --minimum-deployment-target "$ACTOOL_TARGET" --app-icon AppIcon \
    --include-all-app-icons --output-partial-info-plist "$REPO_ROOT/build/AppIcon-partial.plist" \
    --output-format human-readable-text 2>&1)" || true
if echo "$ACTOOL_OUT" | grep -qi "error" || [ ! -f "$APP_DIR/Contents/Resources/Assets.car" ]; then
    echo "$ACTOOL_OUT" >&2
    fail "actool failed to compile Support/AppIcon/AppIcon.icon"
fi
ICONSET="$REPO_ROOT/build/AppIcon.iconset"
"$REPO_ROOT/scripts/make-iconset.sh" Support/AppIcon/icon_1024.png "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" "$REPO_ROOT/build/AppIcon-partial.plist"

# Identity: discovered by certificate-type prefix, never by a name written here.
ENTITLEMENTS="$REPO_ROOT/Support/Pelican.entitlements"
SIGN_FLAGS=()
if [ "${DEVELOPER_ID:-0}" = 1 ]; then
    IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' 'index($2, "Developer ID Application") == 1 {print $2; exit}')}"
    [ -n "$IDENTITY" ] || fail "DEVELOPER_ID=1 but no \"Developer ID Application\" identity in the keychain (or set SIGN_IDENTITY)"
    SIGN_FLAGS=(--options runtime --timestamp)
    echo "▸ codesign for distribution ($IDENTITY, hardened runtime)"
else
    IDENTITY="${SIGN_IDENTITY:--}"
    [ "$IDENTITY" = "-" ] && echo "▸ codesign (ad-hoc)" || echo "▸ codesign ($IDENTITY)"
fi
sign() { codesign --force --sign "$IDENTITY" ${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"} "$@"; }

# Stale extended attributes (quarantine, Finder info, an old metallib signature) break sealing.
xattr -cr "$APP_DIR" 2>/dev/null || true
# SwiftPM resource bundles. codesign treats anything named *.bundle as nested code and refuses
# the app while one is unsigned. Flat bundles of loose files get a minimal Info.plist; a flat
# bundle with a Resources/ directory is moved to the deep layout, which codesign understands.
find "$APP_DIR/Contents/Resources" -maxdepth 1 -name '*.bundle' -type d | while read -r bundle; do
    name="$(basename "$bundle" .bundle)"
    plist="$bundle/Info.plist"
    if [ ! -f "$bundle/Contents/Info.plist" ]; then
        if [ -d "$bundle/Resources" ]; then
            mkdir -p "$bundle/Contents"
            rm -f "$bundle/Info.plist"
            for entry in "$bundle"/*; do
                case "$(basename "$entry")" in
                    Contents) ;;
                    Resources) mv "$entry" "$bundle/Contents/" ;;
                    *) mkdir -p "$bundle/Contents/Resources"; mv "$entry" "$bundle/Contents/Resources/" ;;
                esac
            done
            plist="$bundle/Contents/Info.plist"
        fi
        [ -f "$plist" ] || /usr/libexec/PlistBuddy \
            -c "Add :CFBundleIdentifier string nyc.rao.pelican.res.$(echo "$name" | tr '_' '-')" \
            -c "Add :CFBundleName string $name" \
            -c "Add :CFBundlePackageType string BNDL" \
            -c "Add :CFBundleInfoDictionaryVersion string 6.0" \
            "$plist" >/dev/null
    fi
    sign "$bundle"
done
sign --entitlements "$ENTITLEMENTS" "$APP_DIR"
codesign --verify --deep --strict --verbose=1 "$APP_DIR"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_DIR/Contents/Info.plist")"
runtime=false
details="$(codesign -dv "$APP_DIR" 2>&1)"   # captured first: grep -q would SIGPIPE codesign under pipefail
grep -qE 'flags=0x[0-9a-f]+\([^)]*runtime' <<<"$details" && runtime=true
sha="$(shasum -a 256 "$APP_DIR/Contents/MacOS/Pelican" | awk '{print $1}')"
cat > "$METADATA" <<JSON
{
  "version": "$version",
  "build": "$build_number",
  "commit": "$commit",
  "builtAt": "$built_at",
  "signedBy": "$IDENTITY",
  "hardenedRuntime": $runtime,
  "buildSystem": "$BUILD_SYSTEM",
  "executable": "Pelican.app/Contents/MacOS/Pelican",
  "sha256": "$sha"
}
JSON
echo "▸ wrote $METADATA"

if [ "$INSTALL" = 1 ]; then
    echo "▸ installing /Applications/Pelican.app"
    rm -rf /Applications/Pelican.app
    ditto "$APP_DIR" /Applications/Pelican.app
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Pelican.app
fi

echo "Done: $APP_DIR"

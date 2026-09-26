#!/bin/bash
# WHAT: A Developer ID release of Pelican: app → signed .pkg → notarized, stapled installer,
#       with a manifest of exactly what went in and a SHA-256 to publish beside it.
# OUT:  build/Pelican-<version>.pkg           installs /Applications/Pelican.app, then opens it
#       build/Pelican-<version>.pkg.sha256    `shasum -a 256 -c` it after downloading
#       build/Pelican-<version>-manifest.txt  commits, dependency pins and toolchain
# IN:   Keychain identities whose names begin "Developer ID Application" and "Developer ID
#       Installer" (or SIGN_IDENTITY / INSTALLER_IDENTITY naming them), and — unless
#       SKIP_NOTARIZE=1 — a notarytool keychain profile you created, passed as NOTARY_PROFILE:
#         xcrun notarytool store-credentials <any-name> --apple-id <you> --team-id <team>
#         NOTARY_PROFILE=<any-name> ./scripts/make-pkg.sh
#       Clean, committed checkouts of this repository and of Frigate (FRIGATE_DIR).
# PIN:  Pelican is open source and audited by the people it protects: this script names no
#       team, certificate or profile. The team a release must be signed by is read from the
#       identity chosen at run time, then checked on the built app.
# PIN:  arm64 and the macOS floor in Support/Info.plist (pkg/Distribution.xml must agree).
#       Nothing is built from a dirty tree, and a pkg is never overwritten by the same build
#       number: bump CFBundleVersion first, or FORCE=1 to re-release a build that never shipped.
#
#   NOTARY_PROFILE=<name> ./scripts/make-pkg.sh       # everything
#   SKIP_NOTARIZE=1 ./scripts/make-pkg.sh             # stop at the signed .pkg
#   ALLOW_DIRTY=1 SKIP_NOTARIZE=1 ./scripts/make-pkg.sh   # a dry run from uncommitted work
#   FORCE=1 …                                         # overwrite a pkg of this build number
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$REPO_ROOT/build"
APP="$BUILD/Pelican.app"
FRIGATE_DIR="${FRIGATE_DIR:-$REPO_ROOT/../../rao/repositories/Frigate}"
BUILD_SYSTEM="${PELICAN_BUILD_SYSTEM:-native}"
cd "$REPO_ROOT"

fail() { echo "make-pkg: $*" >&2; exit 1; }

identity() {   # policy prefix → first valid identity whose name starts with prefix
    security find-identity -v -p "$1" 2>/dev/null \
        | awk -F'"' -v kind="$2" 'index($2, kind) == 1 {print $2; exit}'
}

echo "▸ preflight: identities"
APP_IDENTITY="${SIGN_IDENTITY:-$(identity codesigning "Developer ID Application")}"
[ -n "$APP_IDENTITY" ] || fail "no \"Developer ID Application\" identity in the keychain (or set SIGN_IDENTITY)"
INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-$(identity basic "Developer ID Installer")}"
[ -n "$INSTALLER_IDENTITY" ] || fail "no \"Developer ID Installer\" identity in the keychain (or set INSTALLER_IDENTITY)"
# The team the build must carry, from the identity's own name: "… (ABCDE12345)".
TEAM_ID="$(printf '%s' "$APP_IDENTITY" | sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p')"
[ -n "$TEAM_ID" ] || echo "  warning: can't read a team from \"$APP_IDENTITY\"; the team check is skipped"
if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    [ -n "${NOTARY_PROFILE:-}" ] || fail "set NOTARY_PROFILE to a notarytool keychain profile (see the header), or SKIP_NOTARIZE=1"
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        || fail "notarytool can't use keychain profile '$NOTARY_PROFILE'"
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Support/Info.plist)"
PLIST_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Support/Info.plist)"
PKG="$BUILD/Pelican-$VERSION.pkg"
MANIFEST="$BUILD/Pelican-$VERSION-manifest.txt"
echo "  Pelican $VERSION ($BUILD_NUMBER), signing as $APP_IDENTITY"

echo "▸ preflight: sources"
require_clean() {   # name dir
    [ -d "$2/.git" ] || [ -f "$2/.git" ] || fail "$1 is not a git checkout at $2"
    local dirty
    dirty="$(git -C "$2" status --porcelain --untracked-files=normal)"
    [ -z "$dirty" ] && return 0
    if [ "${ALLOW_DIRTY:-0}" = "1" ]; then
        echo "  warning: $1 is dirty at $2 (ALLOW_DIRTY=1)"
        return 0
    fi
    echo "$dirty" | head -20 >&2
    fail "$1 has uncommitted changes at $2 — commit them, or ALLOW_DIRTY=1 for a dry run"
}
require_clean Pelican "$REPO_ROOT"
require_clean Frigate "$FRIGATE_DIR"
DIST_OS="$(sed -nE 's/.*<os-version min="([0-9.]+)".*/\1/p' pkg/Distribution.xml | head -1)"
[ "$DIST_OS" = "$PLIST_OS" ] || fail "pkg/Distribution.xml allows macOS $DIST_OS but Support/Info.plist says $PLIST_OS"
if [ -f "$PKG" ] && [ "${FORCE:-0}" != "1" ]; then
    previous="$(awk '/^build /{print $2}' "$MANIFEST" 2>/dev/null || true)"
    if [ -z "$previous" ] || [ "$previous" = "$BUILD_NUMBER" ]; then
        fail "$PKG exists (build ${previous:-unknown}) — bump CFBundleVersion in Support/Info.plist, or FORCE=1"
    fi
fi

echo "▸ manifest"
mkdir -p "$BUILD"
{
    echo "Pelican $VERSION"
    echo "build $BUILD_NUMBER"
    echo "date $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "pelican $(git -C "$REPO_ROOT" rev-parse HEAD)"
    echo "frigate $(git -C "$FRIGATE_DIR" rev-parse HEAD)"
    if command -v jq >/dev/null; then
        jq -r '.pins[] | "pin \(.identity) \(.state.version // .state.branch // "-") \(.state.revision)"' Package.resolved
    else
        grep -E '"(identity|revision)"' Package.resolved | paste - - | sed -E 's/.*"identity" : "([^"]+)".*"revision" : "([^"]+)".*/pin \1 \2/'
    fi
    echo "xcode   $(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
    echo "swift   $(swift --version 2>/dev/null | head -1)"
    echo "build-system $BUILD_SYSTEM"
    echo "dirty   ${ALLOW_DIRTY:-0}"
} > "$MANIFEST"
sed 's/^/  /' "$MANIFEST"

echo "▸ app"
DEVELOPER_ID=1 SIGN_IDENTITY="$APP_IDENTITY" "$REPO_ROOT/scripts/make-app.sh"

echo "▸ verify the app"
codesign --verify --deep --strict --verbose=2 "$APP"
signature="$(codesign -dv --verbose=2 "$APP" 2>&1)"
grep -q '^Authority=Developer ID Application' <<<"$signature" || fail "the app isn't signed with a Developer ID Application certificate"
grep -qE 'flags=0x[0-9a-f]+\([^)]*runtime' <<<"$signature" || fail "the app lacks the hardened runtime"
grep -q '^Timestamp=' <<<"$signature" || fail "the app's signature has no secure timestamp"
if [ -n "$TEAM_ID" ]; then
    grep -q "^TeamIdentifier=$TEAM_ID\$" <<<"$signature" || fail "the app isn't signed by team $TEAM_ID (from the chosen identity)"
fi
commit_stamp="$(/usr/libexec/PlistBuddy -c 'Print :PelicanBuildCommit' "$APP/Contents/Info.plist")"
if [[ "$commit_stamp" == *-dirty ]] && [ "${ALLOW_DIRTY:-0}" != "1" ]; then
    fail "the app is stamped $commit_stamp"
fi
echo "  PelicanBuildCommit $commit_stamp"

echo "▸ package"
rm -f "$BUILD/Pelican-component.pkg" "$PKG" "$PKG.sha256"
# From a staging root, with relocation off: a relocatable bundle would let the installer
# "upgrade" whatever copy of nyc.rao.pelican macOS last saw (build/Pelican.app on a
# developer's Mac) instead of installing to /Applications.
STAGE="$BUILD/pkg-root"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto --noextattr --noqtn "$APP" "$STAGE/Pelican.app"   # leave build-machine attributes (quarantine, Finder info) behind
pkgbuild --analyze --root "$STAGE" "$BUILD/components.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$BUILD/components.plist"
pkgbuild --root "$STAGE" \
    --component-plist "$BUILD/components.plist" \
    --install-location /Applications \
    --scripts "$REPO_ROOT/pkg/scripts" \
    --identifier nyc.rao.pelican.pkg \
    --version "$VERSION" \
    "$BUILD/Pelican-component.pkg"
rm -rf "$STAGE" "$BUILD/components.plist"
RESOURCES="$BUILD/pkg-resources"
rm -rf "$RESOURCES"
mkdir -p "$RESOURCES"
cp "$REPO_ROOT/LICENSE" "$RESOURCES/LICENSE"
productbuild --distribution "$REPO_ROOT/pkg/Distribution.xml" \
    --resources "$RESOURCES" \
    --package-path "$BUILD" \
    --sign "$INSTALLER_IDENTITY" --timestamp \
    "$PKG"
rm -rf "$RESOURCES" "$BUILD/Pelican-component.pkg"
pkgutil --check-signature "$PKG"

write_checksum() {   # after stapling, which rewrites the pkg
    (cd "$BUILD" && shasum -a 256 "$(basename "$PKG")" > "$(basename "$PKG").sha256")
    echo "  $(cat "$PKG.sha256")"
}

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    write_checksum
    echo "Skipped notarization. Signed, unnotarized: $PKG"
    echo "Manifest: $MANIFEST"
    exit 0
fi

echo "▸ notarize"
submit="$(xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || true
echo "$submit" | sed 's/^/  /'
if ! grep -q "status: Accepted" <<<"$submit"; then
    id="$(sed -nE 's/^ *id: ([0-9a-f-]+).*/\1/p' <<<"$submit" | head -1)"
    fail "notarization was not accepted${id:+ — details: xcrun notarytool log $id --keychain-profile \"$NOTARY_PROFILE\"}"
fi

echo "▸ staple"
xcrun stapler staple "$PKG"
xcrun stapler validate "$PKG"
# The pkg's ticket lists every nested cdhash, so build/Pelican.app can carry it too.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "▸ assess"
codesign --verify --deep --strict "$APP"
spctl --assess --type install --verbose "$PKG"
spctl --assess --type exec --verbose "$APP"

write_checksum
echo "Done: $PKG"
echo "      $PKG.sha256"
echo "      $MANIFEST"
if git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    echo "Tag:  git tag -a v$VERSION-$BUILD_NUMBER -m 'Pelican $VERSION ($BUILD_NUMBER)' && git push origin v$VERSION-$BUILD_NUMBER"
else
    echo "Tag:  git tag -a v$VERSION -m 'Pelican $VERSION ($BUILD_NUMBER)' && git push origin v$VERSION"
fi

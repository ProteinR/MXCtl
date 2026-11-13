#!/usr/bin/env bash
# Build a universal (Apple Silicon + Intel) Release MXCtl.app, sign it and pack it into
# build/release/MXCtl-<version>.dmg (the app and a link to /Applications) and a .zip (what the
# in-app updater downloads). Used by .github/workflows/release.yml; works locally too.
# MXCTL_SIGN_IDENTITY names the signing certificate (CI: the release certificate imported from the
# repository secrets); without it the app stays ad-hoc signed and cannot update itself.
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(sed -nE 's/^ *MARKETING_VERSION: *"?([0-9.]+)"?.*/\1/p' project.yml)
app=build/dd-release/Build/Products/Release/MXCtl.app
out=build/release
rm -rf build/dd-release "$out"
mkdir -p "$out"

xcodegen generate -q
xcodebuild -project MXCtl.xcodeproj -scheme MXCtl -configuration Release \
  -derivedDataPath build/dd-release ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build -quiet
lipo -info "$app/Contents/MacOS/MXCtl"

if [ -n "${MXCTL_SIGN_IDENTITY:-}" ]; then
  # A stable certificate: macOS ties Accessibility / Input Monitoring to it, so they survive
  # updates, and the updater only installs a copy signed with the same certificate.
  codesign --force --deep -s "$MXCTL_SIGN_IDENTITY" "$app"
  codesign --verify --deep --strict "$app"
  codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => /designated requirement: /p'
else
  echo "warning: MXCTL_SIGN_IDENTITY not set; the release stays ad-hoc signed" >&2
fi

ditto -c -k --keepParent "$app" "$out/MXCtl-$version.zip"
stage=$(mktemp -d)
ditto "$app" "$stage/MXCtl.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "MXCtl $version" -srcfolder "$stage" -format UDZO \
  -fs HFS+ "$out/MXCtl-$version.dmg"
rm -rf "$stage"
# The build copy would show up as another MXCtl in Launchpad / Spotlight.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u "$PWD/$app" 2>/dev/null || true
rm -rf "$app"
(cd "$out" && shasum -a 256 MXCtl-* | tee SHA256SUMS)

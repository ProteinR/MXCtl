#!/usr/bin/env bash
# Build MXCtl (ad-hoc signed) and install it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate -q
xcodebuild -project MXCtl.xcodeproj -scheme MXCtl -configuration Release \
  -derivedDataPath build/dd build -quiet
# Re-sign with the stable local certificate (the one MeetRec uses). Its designated requirement is the
# certificate, not the build hash, so the Accessibility permission survives rebuilds.
IDENTITY="dmemruk Local Code Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  # PROFILE=1: also allow attaching tools (leaks, Instruments allocations); same certificate, so
  # the permissions stay.
  if [ "${PROFILE:-0}" = "1" ]; then
    codesign --force --deep -s "$IDENTITY" --entitlements scripts/profile.entitlements build/dd/Build/Products/Release/MXCtl.app
  else
    codesign --force --deep -s "$IDENTITY" build/dd/Build/Products/Release/MXCtl.app
  fi
else
  echo "warning: certificate '$IDENTITY' not found; app stays ad-hoc signed and permissions reset on every rebuild" >&2
fi
# Quit gracefully; kill only if it does not quit in time.
if pgrep -qx MXCtl; then
  osascript -e 'tell application id "com.dmemruk.MXCtl" to quit' >/dev/null 2>&1 || true
fi
for _ in $(seq 1 50); do pgrep -qx MXCtl || break; sleep 0.2; done
pkill -x MXCtl 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/MXCtl.app
ditto build/dd/Build/Products/Release/MXCtl.app ~/Applications/MXCtl.app
# The build copy would show up as a second MXCtl in Launchpad / Spotlight: remove it.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$PWD/build/dd/Build/Products/Release/MXCtl.app" 2>/dev/null || true
rm -rf build/dd/Build/Products/Release/MXCtl.app
open ~/Applications/MXCtl.app
echo "Installed ~/Applications/MXCtl.app"

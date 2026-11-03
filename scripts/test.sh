#!/usr/bin/env bash
# Run the unit tests, then remove the Debug app they need as a host: an ad-hoc signed second copy
# with the same bundle ID confuses macOS permissions (Input Monitoring / Accessibility end up
# attached to it instead of ~/Applications/MXCtl.app).
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate -q
status=0
xcodebuild -project MXCtl.xcodeproj -scheme MXCtl -derivedDataPath build/dd test -quiet || status=$?
DEBUG_APP="build/dd/Build/Products/Debug/MXCtl.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$PWD/$DEBUG_APP" 2>/dev/null || true
rm -rf "$DEBUG_APP"
exit $status

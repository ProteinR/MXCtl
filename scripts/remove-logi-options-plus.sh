#!/usr/bin/env bash
# Removes Logi Options+ (MXCtl replaces it). Logitech ships no uninstaller for it on macOS; dragging
# the app to the Trash leaves its agent, updater daemon and ~2 GB of downloaded updates behind.
#
#   scripts/remove-logi-options-plus.sh              # dry run: only lists what it would do
#   scripts/remove-logi-options-plus.sh --yes        # does it (asks for the admin password once)
#   scripts/remove-logi-options-plus.sh --yes --with-rightsight
#                                                    # also Logi RightSight (webcam software)
#
# Nothing is deleted: everything goes into one folder in the Trash ("Logi Options+ <date>"), so it
# can be put back until the Trash is emptied. MXCtl keeps its own copy of the device pictures.
set -euo pipefail

DO=0
RIGHTSIGHT=0
for arg in "$@"; do
  case "$arg" in
    --yes) DO=1 ;;
    --with-rightsight) RIGHTSIGHT=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

UID_NUM=$(id -u)
TRASH="$HOME/.Trash/Logi Options+ $(date +%Y-%m-%d_%H-%M)"

ITEMS=(
  "/Applications/logioptionsplus.app"
  "/Applications/Utilities/LogiPluginService.app"
  "/Applications/Utilities/Logi Options+ Driver Installer.bundle"
  "/Library/Application Support/Logitech.localized/LogiOptionsPlus"
  "/Library/Application Support/Logi"
  "/Library/LaunchAgents/com.logi.optionsplus.plist"
  "/Library/LaunchDaemons/com.logi.optionsplus.updater.plist"
  "$HOME/Library/Application Support/LogiOptionsPlus"
  "$HOME/Library/Application Support/Logi"
  "$HOME/Library/Application Support/com.logitech.logiaipromptbuilder"
  "$HOME/Library/Logs/xlog_logitech"
  "$HOME/Library/Preferences/com.logi.cp-dev-mgr.plist"
  "$HOME/Library/Preferences/com.logi.lps.settings.plist"
  "$HOME/Library/Preferences/com.logi.optionsplus.driverhost.plist"
  "$HOME/Library/Preferences/com.logi.optionsplus.plist"
  "$HOME/Library/Preferences/com.logi.pluginservice.plist"
  "$HOME/Library/Preferences/com.logitech.logiaipromptbuilder.plist"
)
PACKAGES=(com.logi.installer.pluginservice.package com.logi.installer.pluginservice.media.package)
if [ "$RIGHTSIGHT" = 1 ]; then
  ITEMS+=(
    "/Library/Application Support/Logitech.localized/LogiRightSightForWebcams"
    "/Library/LaunchAgents/com.logitech.LogiRightSight.Agent.plist"
  )
  PACKAGES+=(com.logitech.LogiRightSightForWebcams.pkg)
fi

run() {
  if [ "$DO" = 1 ]; then "$@"; else echo "  would run: $*"; fi
}

echo "1. Stop Logi Options+"
run launchctl bootout "gui/$UID_NUM/com.logi.cp-dev-mgr" 2>/dev/null || true
run sudo launchctl bootout system/com.logi.optionsplus.updater 2>/dev/null || true
run osascript -e 'tell application id "com.logi.pluginservice" to quit' 2>/dev/null || true
if [ "$RIGHTSIGHT" = 1 ]; then
  run launchctl bootout "gui/$UID_NUM/com.logitech.LogiRightSight.Agent" 2>/dev/null || true
fi
run sudo pkill -f "logioptionsplus|LogiPluginService|logi_crashpad_handler" 2>/dev/null || true
[ "$RIGHTSIGHT" = 1 ] && run sudo pkill -f LogiRightSight 2>/dev/null || true

echo "2. Move to the Trash: $TRASH"
run mkdir -p "$TRASH"
total=0
for item in "${ITEMS[@]}"; do
  [ -e "$item" ] || continue
  # du complains about files it may not read (Options+ crash reports); the size is still right.
  size=$(du -sk "$item" 2>/dev/null | cut -f1 || true)
  total=$((total + ${size:-0}))
  # Keep the original path in the name, so it is clear where to put it back.
  name=$(echo "${item#/}" | tr '/' '_')
  echo "  $(du -sh "$item" 2>/dev/null | cut -f1 || true)	$item"
  run sudo mv "$item" "$TRASH/$name"
done
echo "  total: $((total / 1024)) MB"
# Files stay root-owned in the Trash: macOS does not let Terminal change files inside the Trash even
# with sudo (chown fails with "Operation not permitted"); Finder asks for the password on emptying.

echo "3. Forget the installer receipts"
for package in "${PACKAGES[@]}"; do
  pkgutil --pkg-info "$package" >/dev/null 2>&1 && run sudo pkgutil --forget "$package"
done

# The Logitech folder is gone with its last product.
if [ -d "/Library/Application Support/Logitech.localized" ] && [ -z "$(ls -A "/Library/Application Support/Logitech.localized" 2>/dev/null)" ]; then
  run sudo rmdir "/Library/Application Support/Logitech.localized"
fi

if [ "$DO" = 1 ]; then
  echo "Done. Everything is in the Trash folder above; empty the Trash when sure."
else
  echo "Dry run. Run again with --yes to do it."
fi

#!/bin/bash
# Stops UsageBar, removes the login item and the app.
# Leaves ~/Library/Application Support/UsageBar (the history log) and the "UsageBar Claude" Keychain item in place;
# delete those by hand if you want a full clean-up.
set -uo pipefail
launchctl bootout "gui/$(id -u)/com.bsnydr.usagebar" 2>/dev/null || true
pkill -x UsageBar 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.bsnydr.usagebar.plist"
rm -rf "$HOME/Applications/UsageBar.app"
echo "UsageBar removed."

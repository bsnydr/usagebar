#!/bin/bash
# Builds UsageBar, copies it to ~/Applications, and registers it to start at login (a LaunchAgent).
# Safe to re-run: it replaces the previous copy and restarts the app.
#
# Optional: keep GitHub in sync. In a clone where you have push rights, run once
#     git config usagebar.autopush true
# and from then on a successful reinstall also commits any changes and pushes them.
# Pass a commit message as the first argument: ./install.sh "Lower the warn threshold to 60"
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
LABEL=com.bsnydr.usagebar
DEST="$HOME/Applications/UsageBar.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

# Stop whatever is running (launchd job first, then any copy started by hand) and wait for it to go.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x UsageBar 2>/dev/null || true
for _ in $(seq 1 25); do
  launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break
  sleep 0.2
done

rm -rf "$DEST"
cp -R build/UsageBar.app "$DEST"

ESCAPED_HOME=$(printf '%s' "$HOME" | sed 's/[&|\\]/\\&/g')
sed "s|__HOME__|$ESCAPED_HOME|g" "$LABEL.plist" > "$PLIST"

# launchd can briefly refuse to re-register a label that is still tearing down; retry a few times.
registered=false
for attempt in 1 2 3 4 5; do
  if launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then registered=true; break; fi
  sleep 0.5
done
if [ "$registered" != true ]; then
  echo "Could not register the login item. Try again with: launchctl bootstrap gui/$(id -u) \"$PLIST\"" >&2
  exit 1
fi
echo "UsageBar is running and will start at login. Look for ✱ and ⬡ in the menu bar."

# Sync to GitHub, only when this clone opted in. Runs last, so nothing that failed to build is ever pushed.
if [ "$(git config --get usagebar.autopush 2>/dev/null || true)" = "true" ]; then
  if [ -n "$(git status --porcelain)" ]; then
    git add -A
    git commit -q -m "${1:-Update UsageBar}"
    echo "Committed: $(git log -1 --format=%s)"
  fi
  if git push -q origin HEAD 2>/dev/null; then
    echo "Pushed to $(git remote get-url origin)"
  else
    echo "warning: push to GitHub failed (offline?). Run 'git push' from $(pwd) when you are back online." >&2
  fi
fi

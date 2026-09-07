#!/bin/bash
# Builds build/UsageBar.app from UsageBar.swift. Needs only the Xcode Command Line Tools (swiftc).
set -euo pipefail
cd "$(dirname "$0")"
APP=build/UsageBar.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"
# -target matches LSMinimumSystemVersion in Info.plist (NSMenuItem.sectionHeader needs macOS 14).
# Build for the architecture this Mac reports (arm64 or x86_64) rather than assuming Apple silicon.
ARCH=$(uname -m)
swiftc -O -swift-version 5 -target "$ARCH-apple-macosx14.0" -framework AppKit -framework UserNotifications \
  -o "$APP/Contents/MacOS/UsageBar" UsageBar.swift
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null \
  || echo "warning: codesign failed; the executable keeps its linker ad-hoc signature only" >&2
echo "Built $APP"

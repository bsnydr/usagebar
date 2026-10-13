#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
sed '/\/\/ MARK: - Entry point/,$d' UsageBar.swift > "$TEST_DIR/main.swift"
cat tests/ClaudeRenewal.swift >> "$TEST_DIR/main.swift"
swiftc -swift-version 5 -framework AppKit -framework UserNotifications \
  -o "$TEST_DIR/tests" "$TEST_DIR/main.swift"
"$TEST_DIR/tests"

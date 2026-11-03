#!/bin/bash
# Builds the app's code (without its entry point) together with the tests and runs them. No microphone, no app.
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
sed '/^\/\/ MARK: - Entry point/,$d' Otto.swift > "$T/app.swift"
cp tests/ListenerTests.swift "$T/main.swift"
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" "$T/app.swift" "$T/main.swift" -o "$T/tests"
"$T/tests"

#!/bin/bash
# Builds Otto into ~/Applications/Otto.app and (re)starts it. Run it again after any change.
# Nothing updates itself: you rebuild when you choose to (git pull, then ./build.sh).
set -euo pipefail
cd "$(dirname "$0")"

[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] || { echo "Otto needs macOS 14 or later."; exit 1; }
xcode-select -p >/dev/null 2>&1 || { echo "Otto needs Apple's command line tools: xcode-select --install"; exit 1; }
command -v claude >/dev/null || [ -x "$HOME/.local/bin/claude" ] || [ -x /opt/homebrew/bin/claude ] ||
  echo "Note: Claude Code isn't installed yet. Otto needs it: https://claude.com/claude-code"

APP="$HOME/Applications/Otto.app"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
# Compile first, so a compiler error leaves the installed app alone.
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" Otto.swift -o "$STAGE/Otto"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp orbs.js AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.jimjja.otto</string>
<key>CFBundleName</key><string>Otto</string>
<key>CFBundleDisplayName</key><string>Otto</string>
<key>CFBundleExecutable</key><string>Otto</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Otto listens for its wake word and your requests.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Otto turns what you say into text, on this Mac.</string>
<key>NSAppleEventsUsageDescription</key><string>Otto controls apps when you ask it to.</string>
</dict></plist>
PLIST
mv "$STAGE/Otto" "$APP/Contents/MacOS/Otto"

# A stable signing identity lets macOS keep Microphone, Accessibility and Screen Recording access across rebuilds
# (an ad hoc signature changes every build, so macOS would ask again each time). It is made once, in your login keychain.
# The key isn't pre-authorized for codesign, so other software can't silently sign as this app: macOS asks the
# first time a build uses it. Click "Always Allow".
NAME="Otto Local Signing"
if ! security find-identity -p codesigning | grep -q "$NAME"; then
  K=$(mktemp -d)
  PASS=$(/usr/bin/openssl rand -hex 16)
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
    -addext "extendedKeyUsage=critical,codeSigning" -addext "keyUsage=critical,digitalSignature" \
    -keyout "$K/key.pem" -out "$K/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$K/key.pem" -in "$K/cert.pem" -out "$K/id.p12" -passout "pass:$PASS" 2>/dev/null
  security import "$K/id.p12" -P "$PASS" -k "$HOME/Library/Keychains/login.keychain-db" >/dev/null || echo "Couldn't add a signing identity; using ad hoc signing."
  rm -rf "$K"
fi
if security find-identity -p codesigning | grep -q "$NAME"; then
  codesign --force --sign "$NAME" "$APP"
else
  codesign --force --sign - "$APP"
fi

# Register with Launch Services so System Settings can list it under Privacy & Security.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

[ -n "${OTTO_NO_LAUNCH:-}" ] && exit 0
pkill -x Otto 2>/dev/null && sleep 1 || true
open "$APP"
echo "Otto is running. Say “Hey Otto” (or your own wake word), or press Control+Option+Space."

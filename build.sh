#!/bin/bash
# Builds EjectOnSleep.app, installs it to ~/Applications and opens it.
set -e
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "Swift compiler not found. Installing Xcode Command Line Tools..."
    xcode-select --install || true
    echo "Finish the install popup, then run ./build.sh again."
    exit 1
fi

APP="build/EjectOnSleep.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS"

swiftc -O -parse-as-library \
    -target "$(uname -m)-apple-macos13.0" \
    Sources/EjectOnSleepApp.swift \
    -o "$APP/Contents/MacOS/EjectOnSleep"

cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

mkdir -p ~/Applications
pkill -x EjectOnSleep 2>/dev/null || true
rm -rf ~/Applications/EjectOnSleep.app
cp -R "$APP" ~/Applications/EjectOnSleep.app

open ~/Applications/EjectOnSleep.app
echo ""
echo "Done. Look for the eject icon in the menu bar."
echo "Open its menu and switch on 'Launch at login'."

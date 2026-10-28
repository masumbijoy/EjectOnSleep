# Eject on Sleep

Menu bar app for macOS 13+. Ejects all external drives when the Mac goes to sleep.
No Homebrew needed.

## Install
1. Open Terminal in this folder (`cd` into it).
2. Run: `chmod +x build.sh && ./build.sh`
   (first run may ask to install Xcode Command Line Tools; accept, then run again)
3. If macOS blocks the app: right-click ~/Applications/EjectOnSleep.app > Open.
4. Click the eject icon in the menu bar and switch on "Launch at login".

## Open in Xcode instead
File > New > Project > macOS App (SwiftUI), replace the default files with
Sources/EjectOnSleepApp.swift, remove App Sandbox in Signing & Capabilities,
and set "Application is agent (UIElement)" = YES in Info.

## Uninstall
    pkill -x EjectOnSleep; rm -rf ~/Applications/EjectOnSleep.app
Then remove it from System Settings > General > Login Items if listed.

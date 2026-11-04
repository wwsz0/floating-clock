#!/bin/zsh
set -eu
cd "${0:A:h}"
APP="$PWD/悬浮时钟.app"
plutil -lint Info.plist
mkdir -p "$APP/Contents/MacOS"
printf '{"version":0,"roots":[{"type":"file","name":"/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap","external-contents":"%s/empty.modulemap"}]}' "$PWD" > compiler-overlay.json
swiftc main.swift Quota.swift Appearance.swift -O -vfsoverlay "$PWD/compiler-overlay.json" -module-cache-path /private/tmp/floating-clock-module-cache-v2 -framework AppKit -o "$APP/Contents/MacOS/FloatingClock"
cp Info.plist "$APP/Contents/Info.plist"
if xattr -p com.apple.FinderInfo "$APP" >/dev/null 2>&1; then
    xattr -d com.apple.FinderInfo "$APP"
fi
codesign --force --sign - "$APP"
printf '已生成：%s\n' "$APP"

#!/bin/zsh
set -eu
cd "${0:A:h}"
APP="$PWD/悬浮时钟.app"
BUILD="$PWD/.build"
ARCHITECTURES="${FLOATING_CLOCK_ARCHS:-$(uname -m)}"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
plutil -lint Info.plist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD/module-cache"
printf '{"version":0,"roots":[{"type":"file","name":"/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap","external-contents":"%s/empty.modulemap"}]}' "$PWD" > compiler-overlay.json
BINARIES=()
for ARCH in ${=ARCHITECTURES}; do
    BINARY="$BUILD/FloatingClock-$ARCH"
    swiftc main.swift Quota.swift Appearance.swift QuotaAlerts.swift QuotaSpeechBubble.swift QuotaAlertTests.swift -O -target "$ARCH-apple-macosx$MIN_OS" -vfsoverlay "$PWD/compiler-overlay.json" -module-cache-path "$BUILD/module-cache" -framework AppKit -o "$BINARY"
    BINARIES+=("$BINARY")
done
lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/FloatingClock"
cp Info.plist "$APP/Contents/Info.plist"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if xattr -p com.apple.FinderInfo "$APP" >/dev/null 2>&1; then
    xattr -d com.apple.FinderInfo "$APP"
fi
codesign --force --sign - "$APP"
printf '已生成：%s\n' "$APP"

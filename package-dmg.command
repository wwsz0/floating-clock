#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"

FLOATING_CLOCK_ARCHS="arm64 x86_64" ./build.command
APP="$PWD/悬浮时钟.app"
"$APP/Contents/MacOS/FloatingClock" --self-test
codesign --verify --verbose "$APP"
lipo "$APP/Contents/MacOS/FloatingClock" -verify_arch arm64 x86_64

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)"
mkdir -p dist .build
BASE="$PWD/dist/FloatingClock-$VERSION-build$BUILD_NUMBER-universal"
OUTPUT="$BASE.dmg"
REVISION=2
while [[ -e "$OUTPUT" || -e "$OUTPUT.sha256" ]]; do
    OUTPUT="$BASE-r$REVISION.dmg"
    REVISION=$((REVISION + 1))
done

WORK="$(mktemp -d "$PWD/.build/dmg.XXXXXXXX")"
STAGE="$WORK/content"
MOUNT=""
MOUNTED=0
cleanup() {
    if (( MOUNTED )); then
        if ! hdiutil detach "$MOUNT" -quiet; then
            printf '映像仍挂载，临时目录已保留：%s\n' "$WORK" >&2
            return
        fi
    fi
    /bin/rm -rf -- "$WORK"
}
trap cleanup EXIT
mkdir -p "$STAGE"
ditto --noextattr --noqtn "$APP" "$STAGE/悬浮时钟.app"
ln -s /Applications "$STAGE/应用程序"
cp Assets/安装说明.txt "$STAGE/安装说明.txt"
codesign --verify --verbose "$STAGE/悬浮时钟.app"

hdiutil create -volname '悬浮时钟' -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -nospotlight "$OUTPUT"
hdiutil verify "$OUTPUT"
hdiutil attach -readonly -nobrowse -noautoopen -plist "$OUTPUT" > "$WORK/attachment.plist"
ENTITY=0
while /usr/libexec/PlistBuddy -c "Print :system-entities:$ENTITY" "$WORK/attachment.plist" >/dev/null 2>&1; do
    MOUNT="$(/usr/libexec/PlistBuddy -c "Print :system-entities:$ENTITY:mount-point" "$WORK/attachment.plist" 2>/dev/null || true)"
    [[ -n "$MOUNT" ]] && break
    ENTITY=$((ENTITY + 1))
done
[[ -n "$MOUNT" ]]
MOUNTED=1
codesign --verify --verbose "$MOUNT/悬浮时钟.app"
cmp "$APP/Contents/MacOS/FloatingClock" "$MOUNT/悬浮时钟.app/Contents/MacOS/FloatingClock"
cmp Assets/AppIcon.icns "$MOUNT/悬浮时钟.app/Contents/Resources/AppIcon.icns"
[[ "$(readlink "$MOUNT/应用程序")" == /Applications ]]
"$MOUNT/悬浮时钟.app/Contents/MacOS/FloatingClock" --self-test
hdiutil detach "$MOUNT"
MOUNTED=0

(
    cd "${OUTPUT:h}"
    shasum -a 256 "${OUTPUT:t}" > "${OUTPUT:t}.sha256"
)
printf '\n已生成安装包：%s\n校验文件：%s.sha256\n' "$OUTPUT" "$OUTPUT"

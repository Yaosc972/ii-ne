#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
# 本机 CommandLineTools 的 PackageDescription 较旧；存在兼容层时自动使用，避免裸 swift build 失败。
if [ -x "$SCRIPT_DIR/.env-tools/swiftc-manifest" ]; then
    export SWIFT_EXEC_MANIFEST="$SCRIPT_DIR/.env-tools/swiftc-manifest"
fi
swift build -c release --product Iine
swift build -c release --product snip
APP="Build/ii ne.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Iine "$APP/Contents/MacOS/Iine"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/StatusBarIcon.png Resources/StatusBarIcon@2x.png \
    Resources/MenuItemIcon.png Resources/MenuItemIcon@2x.png "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# 有本地证书就用它签名：ad-hoc 的 CDHash 会随代码变化，辅助功能授权每次重建都要重勾。
SIGN_ID="ii ne Local Signing"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID" \
    && security find-identity -v -p codesigning 2>/dev/null | grep -q "Yaosnap Local Signing"; then
    SIGN_ID="Yaosnap Local Signing"
fi
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    codesign --force --deep --sign "$SIGN_ID" "$APP"
else
    codesign --force --deep --sign - "$APP"
    echo "提示：当前为 ad-hoc 签名，改代码重建后辅助功能授权可能失效。运行一次 Tools/setup-signing.sh 可固定签名。"
fi
echo "Built $APP"

# 装到 /Applications 并重启：菜单栏应用没有 Dock 图标，装在构建目录里重启后就再也找不到。
if [ "${1:-}" = "install" ] || [ "${1:-}" = "installed" ]; then
    DEST="/Applications/ii ne.app"
    osascript -e 'quit app "ii ne"' >/dev/null 2>&1 || true
    osascript -e 'quit application id "com.yaosnap.app"' >/dev/null 2>&1 || true
    APP_PROCESSES='^/Applications/(ii ne\.app/Contents/MacOS/Iine|Yaosnap\.app/Contents/MacOS/Yaosnap)$'
    for attempt in {1..300}; do
        if ! pgrep -f "$APP_PROCESSES" >/dev/null; then break; fi
        sleep 0.1
    done
    if pgrep -f "$APP_PROCESSES" >/dev/null; then
        echo "应用仍在保存或等待退出，请稍后重试安装。"
        exit 1
    fi
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    codesign --verify --deep --strict "$DEST"
    LEGACY_APP="/Applications/Yaosnap.app"
    if [ -d "$LEGACY_APP" ] \
        && [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$LEGACY_APP/Contents/Info.plist" 2>/dev/null)" = "com.yaosnap.app" ]; then
        rm -rf "$LEGACY_APP"
    fi
    xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
    open -a "$DEST"
    echo "Installed $DEST"
fi

CLI="$SCRIPT_DIR/.build/release/snip"
echo "Built CLI $CLI"
echo "加入 PATH（写入你的 shell 配置）：export PATH=\"$SCRIPT_DIR/.build/release:\$PATH\""

#!/bin/bash
# 编译并运行设置窗口验收 harness：真实构造 SettingsWindowController，
# 验证控件数量、热键录制、Esc 取消、失败标红与 UserDefaults 回写。
set -euo pipefail
cd "$(dirname "$0")/../.."

if [ "${IINE_SKIP_BUILD:-0}" != "1" ]; then
    ./build.sh
fi

mkdir -p /tmp/iine-verify/build

swiftc -O -target "$(uname -m)-apple-macos12.0" \
    -I "$PWD/.build/release" \
    Sources/Iine/UI/AppComponents.swift \
    Sources/Iine/UI/FormControls.swift \
    Sources/Iine/Settings/SettingsWindowController.swift \
    Tools/verify/SettingsE2E.swift \
    "$PWD/.build/release/IineCore.o" \
    -o /tmp/iine-verify/build/settingsharness

if [ "${IINE_COMPILE_ONLY:-0}" != "1" ]; then
    /tmp/iine-verify/build/settingsharness
fi

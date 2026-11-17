#!/bin/bash
# 编译并运行 P3 贴图验收 harness。
# 直接复用生产源码 PinWindow / PinController 与 IineCore，程序化驱动剪贴板贴图。
set -euo pipefail
cd "$(dirname "$0")/../.."

if [ "${IINE_SKIP_BUILD:-0}" != "1" ]; then
    ./build.sh
fi

mkdir -p /tmp/iine-verify/build /tmp/iine-verify/evidence

swiftc -O -target "$(uname -m)-apple-macos12.0" \
    -I "$PWD/.build/release" \
    Sources/Iine/Pin/PinWindow.swift \
    Sources/Iine/Pin/PinController.swift \
    Sources/Iine/Pin/PinToolbar.swift \
    Sources/Iine/UI/AppComponents.swift \
    Sources/Iine/Pin/PinAnnotateBar.swift \
    Sources/Iine/Annotate/ToolbarGlyphs.swift \
    Sources/Iine/Annotate/AnnotateToolbar.swift \
    Sources/Iine/Annotate/AnnotationCanvas.swift \
    Sources/Iine/Annotate/ToolStyleStore.swift \
    Tools/verify/P3PinE2E.swift \
    "$PWD/.build/release/IineCore.o" \
    -o /tmp/iine-verify/build/p3pinharness

if [ "${IINE_COMPILE_ONLY:-0}" != "1" ]; then
    /tmp/iine-verify/build/p3pinharness
fi

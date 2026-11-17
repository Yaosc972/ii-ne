#!/bin/bash
# 编译并运行 P1 验收 harness。
# 直接复用生产源码（SnipController / OverlayView / SnipOverlayWindow）与 IineCore，
# 程序化驱动 start / 拖拽 / 按键 / 复制 / 保存，截图写到 /tmp/iine-verify/evidence。
set -euo pipefail
cd "$(dirname "$0")/../.."

if [ "${IINE_SKIP_BUILD:-0}" != "1" ]; then
    ./build.sh
fi

mkdir -p /tmp/iine-verify/build /tmp/iine-verify/evidence

swiftc -O -target "$(uname -m)-apple-macos12.0" \
    -I "$PWD/.build/release" \
    Sources/Iine/Snip/SnipController.swift \
    Sources/Iine/Snip/OverlayView.swift \
    Sources/Iine/Snip/SnipOverlayWindow.swift \
    Sources/Iine/Snip/TranslationResultWindow.swift \
    Sources/Iine/UI/AppComponents.swift \
    Sources/Iine/UI/FormControls.swift \
    Sources/Iine/Annotate/AnnotateToolbar.swift \
    Sources/Iine/Annotate/ToolbarGlyphs.swift \
    Sources/Iine/Annotate/AnnotationCanvas.swift \
    Sources/Iine/Annotate/ToolStyleStore.swift \
    Sources/Iine/Scroll/ScrollCaptureController.swift \
    Sources/Iine/Scroll/ScrollFrameCapturer.swift \
    Sources/Iine/Scroll/ScrollDebug.swift \
    Sources/Iine/Scroll/ScrollResultWindow.swift \
    Sources/Iine/StatusItemController.swift \
    Tools/verify/P1E2E.swift \
    "$PWD/.build/release/IineCore.o" \
    -o /tmp/iine-verify/build/p1harness

if [ "${IINE_COMPILE_ONLY:-0}" != "1" ]; then
    /tmp/iine-verify/build/p1harness
fi

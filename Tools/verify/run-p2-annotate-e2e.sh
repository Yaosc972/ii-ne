#!/bin/bash
# 编译并运行 P2 标注验收 harness（第一批：矩形垂直切片）。
# 直接复用生产源码与 IineCore，程序化驱动画标注 / 复制 / 状态机行为。
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
    Sources/Iine/Scroll/ScrollCaptureController.swift \
    Sources/Iine/Scroll/ScrollFrameCapturer.swift \
    Sources/Iine/Scroll/ScrollDebug.swift \
    Sources/Iine/Scroll/ScrollResultWindow.swift \
    Sources/Iine/Annotate/AnnotateToolbar.swift \
    Sources/Iine/Annotate/ToolbarGlyphs.swift \
    Sources/Iine/Annotate/AnnotationCanvas.swift \
    Sources/Iine/Annotate/ToolStyleStore.swift \
    Tools/verify/P2AnnotateE2E.swift \
    "$PWD/.build/release/IineCore.o" \
    -o /tmp/iine-verify/build/p2annotateharness

if [ "${IINE_COMPILE_ONLY:-0}" != "1" ]; then
    /tmp/iine-verify/build/p2annotateharness
fi

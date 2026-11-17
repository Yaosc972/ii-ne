#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
if [ "${IINE_SKIP_BUILD:-0}" != "1" ]; then
    ./build.sh
fi
DEST="${1:-/tmp/iine-resource-bench}"
sources=()
while IFS= read -r source; do
    case "$source" in */main.swift) ;; *) sources+=("$source") ;; esac
done < <(rg --files Sources/Iine -g '*.swift' | sort)
swiftc -O -target "$(uname -m)-apple-macos12.0" -I "$PWD/.build/release" \
    "${sources[@]}" Tools/verify/ResourceBench.swift "$PWD/.build/release/IineCore.o" -o "$DEST"
printf '%s\n' "$DEST"

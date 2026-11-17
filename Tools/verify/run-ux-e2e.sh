#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

if [ "${IINE_SKIP_BUILD:-0}" != "1" ]; then
    ./build.sh
fi

mkdir -p /tmp/iine-verify/build /tmp/iine-verify/evidence/ux
sources=()
while IFS= read -r source; do
    case "$source" in
        */main.swift) ;;
        *) sources+=("$source") ;;
    esac
done < <(rg --files Sources/Iine -g '*.swift' | sort)

swiftc -O -target "$(uname -m)-apple-macos12.0" \
    -I "$PWD/.build/release" \
    "${sources[@]}" \
    Tools/verify/UXE2E.swift \
    "$PWD/.build/release/IineCore.o" \
    -o /tmp/iine-verify/build/uxharness

if [ "${IINE_COMPILE_ONLY:-0}" = "1" ]; then
    exit 0
fi

/tmp/iine-verify/build/uxharness | tee /tmp/iine-verify/ux-result.log
if ! rg -q '^SUMMARY passes=[1-9][0-9]* failures=0$' /tmp/iine-verify/ux-result.log; then
    echo "FAIL UX verification did not finish with a passing summary"
    exit 1
fi

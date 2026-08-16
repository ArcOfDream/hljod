#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-build}"

build_desktop() { odin build desktop/ -debug -out:hljod; }

build_web() {
    (cd web && npm exec tsc 2>/dev/null || echo "tsc: non-zero exit, JS output still usable")
    odin build web/main.odin -file -target:js_wasm32 \
        -extra-linker-flags:--import-memory -out:web/hljod.wasm
}

case "$ACTION" in
    build)  build_desktop ;;
    run)    build_desktop && ./hljod ;;
    release)
        mkdir -p build/linux
        odin build desktop/ -o:speed -out:build/linux/hljod
        cp -r desktop/fonts build/linux/fonts
        ;;
    check)      odin check desktop/ ;;
    web)        build_web ;;
    web-check)  odin check web/main.odin -file -target:js_wasm32 ;;
    serve)
        build_web
        echo "Open http://localhost:9090 in your browser"
        python3 -m http.server 9090 --directory web
        ;;
    *)
        echo "Usage: $0 [build|run|release|check|web|web-check|serve]"
        exit 1
        ;;
esac

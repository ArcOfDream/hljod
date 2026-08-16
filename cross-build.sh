#!/bin/bash
# hljod Windows cross-compile via mingw
# Requires: x86_64-w64-mingw32-gcc/g++, Odin compiler, curl
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

SDL3_VERSION="3.4.10"
SDL3_TARBALL="SDL3-devel-${SDL3_VERSION}-mingw.tar.gz"
SDL3_URL="https://github.com/libsdl-org/SDL/releases/download/release-${SDL3_VERSION}/${SDL3_TARBALL}"
SDL3_CACHE=".cache/sdl3"
SDL3_DIR="${SDL3_CACHE}/SDL3-${SDL3_VERSION}/x86_64-w64-mingw32"
SDL3_LIB="${SDL3_DIR}/lib/libSDL3.dll.a"
SDL3_DLL="${SDL3_DIR}/bin/SDL3.dll"

IMGUI_LIB="$SCRIPT_DIR/vendor/imgui/imgui_windows_x64.lib"
OBJ_DIR="$SCRIPT_DIR/build/tmp-win64"
OUT_DIR="build/win32"

# Download SDL3 mingw devel if not cached
if [ ! -f "$SDL3_DLL" ]; then
    echo "Downloading SDL3 ${SDL3_VERSION} mingw devel..."
    mkdir -p "$SDL3_CACHE"
    curl -L -o "${SDL3_CACHE}/${SDL3_TARBALL}" "$SDL3_URL"
    tar xzf "${SDL3_CACHE}/${SDL3_TARBALL}" -C "$SDL3_CACHE"
    rm -f "${SDL3_CACHE}/${SDL3_TARBALL}"
else
    echo "SDL3 already cached: $SDL3_CACHE"
fi

# Build imgui (dcimgui + backends) for Windows with mingw.
# The committed imgui_windows_x64.lib is MSVC-built and fails mingw linking
# (missing __local_stdio_printf_options / __security_cookie), so rebuild it.
# Backends need IMGUI_IMPL_API=extern"C" so symbols are C (not mangled).
echo "Building imgui for Windows (mingw)..."
IMGUI_TMP=$(mktemp -d)
trap 'rm -rf "$IMGUI_TMP"' EXIT
cd vendor/imgui
for f in \
    imgui/imgui.cpp imgui/imgui_draw.cpp imgui/imgui_tables.cpp \
    imgui/imgui_widgets.cpp imgui/imgui_demo.cpp \
    dcimgui/dcimgui_nodefaultargfunctions.cpp \
    dcimgui/dcimgui_nodefaultargfunctions_internal.cpp \
    imgui/backends/imgui_impl_sdl3.cpp \
    imgui/backends/imgui_impl_sdlrenderer3.cpp; do
    b=$(basename "$f" .cpp)
    x86_64-w64-mingw32-g++ -c -O2 -std=c++11 \
        -fno-exceptions -fno-rtti -fno-threadsafe-statics \
        -DIMGUI_DISABLE_OBSOLETE_FUNCTIONS \
        -D'IMGUI_IMPL_API=extern"C"' \
        -I. -Iimgui -Iimgui/backends -I"${SCRIPT_DIR}/${SDL3_DIR}/include" \
        "$f" -o "${IMGUI_TMP}/${b}.o"
done
# the committed lib carries MSVC-built members that mingw
# can't link (missing __GSHandlerCheck); replace it entirely
rm -f "$IMGUI_LIB"
x86_64-w64-mingw32-ar rcs "$IMGUI_LIB" "${IMGUI_TMP}"/*.o
cd "$SCRIPT_DIR"
echo "imgui built: $IMGUI_LIB"

# Odin build as .obj files
echo "Building hljod .obj files for Windows..."
rm -rf "$OBJ_DIR"
mkdir -p "$OBJ_DIR"
odin build desktop/ -build-mode:obj -target:windows_amd64 \
    -out:"${OBJ_DIR}/hljod.obj" -o:speed

# Link with mingw
echo "Linking hljod.exe..."
mkdir -p "$OUT_DIR"
# Odin's runtime calls MSVC's __chkstk, bridge to mingw's ___chkstk_ms
cat > "${OBJ_DIR}/chkstk_shim.c" << 'SHIMEOF'
extern void ___chkstk_ms(void);
void __chkstk(void) { ___chkstk_ms(); }
SHIMEOF
x86_64-w64-mingw32-gcc -c -O2 -o "${OBJ_DIR}/chkstk_shim.o" "${OBJ_DIR}/chkstk_shim.c"

x86_64-w64-mingw32-g++ \
    "${OBJ_DIR}"/hljod*.obj \
    "$IMGUI_LIB" \
    "${OBJ_DIR}/chkstk_shim.o" \
    -static-libgcc -static-libstdc++ \
    -L"${SDL3_DIR}/lib" \
    -lSDL3 \
    -lkernel32 -luser32 -lgdi32 -lopengl32 -ladvapi32 -lbcrypt -ld3d11 -ldxgi \
    -mwindows \
    -o "$OUT_DIR/hljod.exe"

# Copy runtime files
cp "$SDL3_DLL" "$OUT_DIR/"
# ...turns out libwinpthread exists in lib under debian, not bin like in arch
cp /usr/x86_64-w64-mingw32/lib/libwinpthread-1.dll "$OUT_DIR/"
cp -r desktop/fonts "$OUT_DIR/fonts"

# Cleanup
rm -rf "$OBJ_DIR"

echo ""
echo "Build complete: build/win32/hljod.exe"
